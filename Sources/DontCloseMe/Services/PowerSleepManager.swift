import Foundation
import AppKit
import IOKit.pwr_mgt
import IOKit.ps

enum ClamshellAuthStatus: Equatable {
    case notAuthorized
    case authorizing
    case authorizedActive
    case authorizedStandby
    case failed(String)

    var label: String {
        switch self {
        case .notAuthorized:
            return "Standard Assertion Only (Authorize pmset for lid-closed work without external monitor)"
        case .authorizing:
            return "Waiting for macOS Touch ID / Password prompt..."
        case .authorizedActive:
            return "Clamshell Override ACTIVE (Mac stays awake even with lid closed)"
        case .authorizedStandby:
            return "Watchdog Ready (Will set disablesleep=1 when an agent works)"
        case .failed(let msg):
            return "Authorization error: \(msg)"
        }
    }

    var isAuthorized: Bool {
        switch self {
        case .authorizedActive, .authorizedStandby:
            return true
        default:
            return false
        }
    }

    var isAuthorizing: Bool {
        if case .authorizing = self { return true }
        return false
    }
}

@MainActor
final class PowerSleepManager: ObservableObject {
    @Published private(set) var isStandardAssertionActive: Bool = false
    @Published private(set) var isKernelSleepDisabled: Bool = false
    @Published private(set) var clamshellAuthStatus: ClamshellAuthStatus = .notAuthorized
    @Published private(set) var batteryPercent: Int? = nil
    @Published private(set) var isOnACPower: Bool = true
    @Published private(set) var isPausedForLowBattery: Bool = false

    private var userIdleAssertionID: IOPMAssertionID = 0
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var statusPollTimer: Timer?
    private var activeAuthProcess: Process?
    private var isWatchdogAliveCached = false

    private let appSupportDir: URL
    private let stateFileURL: URL
    private var currentSleepNonce: Int = 0
    private var lastDesiredDisableSleep = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.appSupportDir = base.appendingPathComponent("DontCloseMe", isDirectory: true)
        self.stateFileURL = appSupportDir.appendingPathComponent("clamshell.state")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        writeWatchdogState(wantDisableSleep: false, batteryFloor: 12, triggerSleepNow: false)
        refreshPowerAndPMSetStatus()
        startPolling()
    }

    deinit {
        statusPollTimer?.invalidate()
        activeAuthProcess?.terminate()
        if userIdleAssertionID != 0 {
            IOPMAssertionRelease(userIdleAssertionID)
        }
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
        }
    }

    func updatePowerPolicy(
        keepAwakeEnabled: Bool,
        isAnyAgentWorking: Bool,
        batteryFloor: Int
    ) {
        refreshBatteryStatus()

        let lowBatt = !isOnACPower && (batteryPercent ?? 100) <= batteryFloor
        isPausedForLowBattery = lowBatt

        let shouldHoldAwake = keepAwakeEnabled && isAnyAgentWorking && !lowBatt
        if shouldHoldAwake {
            acquireAssertionsIfNeeded()
        } else {
            releaseAssertionsIfNeeded()
        }

        lastDesiredDisableSleep = shouldHoldAwake
        writeWatchdogState(
            wantDisableSleep: shouldHoldAwake,
            batteryFloor: batteryFloor,
            triggerSleepNow: false
        )
        refreshClamshellStateLabels()
    }

    func finishAndMaybeSleep(isLidClosed: Bool, autoSleepWhenDone: Bool, batteryFloor: Int) {
        releaseAssertionsIfNeeded()
        lastDesiredDisableSleep = false

        let shouldTriggerSleep = isLidClosed && autoSleepWhenDone
        writeWatchdogState(
            wantDisableSleep: false,
            batteryFloor: batteryFloor,
            triggerSleepNow: shouldTriggerSleep
        )

        if shouldTriggerSleep && !isWatchdogRunning() {
            runNonBlockingCommand("/usr/bin/pmset", args: ["sleepnow"])
        }
        refreshClamshellStateLabels()
    }

    func cancelAuthorization() {
        if let proc = activeAuthProcess, proc.isRunning {
            proc.terminate()
        }
        activeAuthProcess = nil
        clamshellAuthStatus = .notAuthorized
        refreshClamshellStateLabels()
    }

    func authorizeClamshellWatchdog() {
        if isWatchdogRunning() {
            clamshellAuthStatus = lastDesiredDisableSleep ? .authorizedActive : .authorizedStandby
            refreshPowerAndPMSetStatus()
            return
        }
        if clamshellAuthStatus.isAuthorizing {
            return
        }

        guard let watchdogURL = resolveResourceScript(named: "clamshell_watchdog"),
              let launcherURL = resolveResourceScript(named: "launch_watchdog") else {
            clamshellAuthStatus = .failed("Watchdog helper scripts missing from app bundle")
            return
        }

        clamshellAuthStatus = .authorizing
        let appPID = ProcessInfo.processInfo.processIdentifier
        let launcherPath = shellEscaped(launcherURL.path)
        let watchdogPath = shellEscaped(watchdogURL.path)
        let statePath = shellEscaped(stateFileURL.path)

        let shellCmd = "/bin/bash \(launcherPath) \(watchdogPath) \(appPID) \(statePath)"
        let escapedForAppleScript = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScriptSource = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScriptSource]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        activeAuthProcess = proc

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.activeAuthProcess = nil
                    self.clamshellAuthStatus = .failed(error.localizedDescription)
                }
                return
            }

            proc.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = proc.terminationStatus

            if status == 0 {
                // Poll briefly until detached watchdog is visible and pmset applies disablesleep
                var alive = false
                for _ in 0..<15 {
                    if Self.checkWatchdogAliveSync(appPID: appPID) {
                        alive = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                // Give watchdog one brief cycle to run `pmset -a disablesleep 1` if desired
                Thread.sleep(forTimeInterval: 0.25)
                let sleepDisabledNow = Self.readKernelSleepDisabledSync()

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.activeAuthProcess = nil
                    self.isWatchdogAliveCached = alive
                    self.isKernelSleepDisabled = sleepDisabledNow
                    if alive {
                        self.clamshellAuthStatus = (self.lastDesiredDisableSleep || sleepDisabledNow)
                            ? .authorizedActive
                            : .authorizedStandby
                    } else {
                        self.clamshellAuthStatus = .failed("Watchdog did not start after authorization")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.activeAuthProcess = nil
                    let lower = errText.lowercased()
                    if lower.contains("-128") || lower.contains("cancel") || status == 15 {
                        self.clamshellAuthStatus = .notAuthorized
                    } else {
                        self.clamshellAuthStatus = .failed(errText.isEmpty ? "osascript exited \(status)" : errText)
                    }
                }
            }
        }
    }

    func shutdownForAppTermination() {
        if let proc = activeAuthProcess, proc.isRunning {
            proc.terminate()
        }
        releaseAssertionsIfNeeded()
        writeWatchdogState(wantDisableSleep: false, batteryFloor: 12, triggerSleepNow: false)
    }

    private func startPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPowerAndPMSetStatus()
            }
        }
        if let statusPollTimer {
            RunLoop.main.add(statusPollTimer, forMode: .common)
        }
    }

    func refreshPowerAndPMSetStatus() {
        refreshBatteryStatus()
        readKernelAndWatchdogStatusAsync()
        refreshClamshellStateLabels()
    }

    private func refreshClamshellStateLabels() {
        if case .authorizing = clamshellAuthStatus {
            return
        }
        if isWatchdogAliveCached {
            clamshellAuthStatus = (lastDesiredDisableSleep || isKernelSleepDisabled)
                ? .authorizedActive
                : .authorizedStandby
        } else if case .failed = clamshellAuthStatus {
            // Preserve failure text until user retries
        } else {
            clamshellAuthStatus = .notAuthorized
        }
    }

    private func acquireAssertionsIfNeeded() {
        if userIdleAssertionID == 0 {
            var id: IOPMAssertionID = 0
            let reason = "DontCloseMe: Keeping Mac awake while active tool is running" as CFString
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if res == kIOReturnSuccess {
                userIdleAssertionID = id
            }
        }
        if systemSleepAssertionID == 0 {
            var id: IOPMAssertionID = 0
            let reason = "DontCloseMe: Preventing system sleep until active tool finishes" as CFString
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if res == kIOReturnSuccess {
                systemSleepAssertionID = id
            }
        }
        isStandardAssertionActive = (userIdleAssertionID != 0 || systemSleepAssertionID != 0)
    }

    private func releaseAssertionsIfNeeded() {
        if userIdleAssertionID != 0 {
            IOPMAssertionRelease(userIdleAssertionID)
            userIdleAssertionID = 0
        }
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }
        isStandardAssertionActive = false
    }

    private func writeWatchdogState(
        wantDisableSleep: Bool,
        batteryFloor: Int,
        triggerSleepNow: Bool
    ) {
        if triggerSleepNow {
            currentSleepNonce += 1
        }
        let nonce = triggerSleepNow ? currentSleepNonce : 0
        let content = """
        WANT_DISABLE_SLEEP=\(wantDisableSleep ? 1 : 0)
        BATTERY_FLOOR=\(max(5, min(50, batteryFloor)))
        SLEEP_NOW_NONCE=\(nonce)

        """
        try? content.write(to: stateFileURL, atomically: true, encoding: .utf8)
    }

    private func resolveResourceScript(named name: String) -> URL? {
        if let mainURL = Bundle.main.url(forResource: name, withExtension: "sh") {
            return mainURL
        }
        #if SWIFT_PACKAGE
        if let moduleURL = Bundle.module.url(forResource: name, withExtension: "sh") {
            return moduleURL
        }
        #endif
        let fallback = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/\(name).sh")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    private func isWatchdogRunning() -> Bool {
        isWatchdogAliveCached
    }

    private func readKernelAndWatchdogStatusAsync() {
        let appPID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disabled = Self.readKernelSleepDisabledSync()
            let watchdogRunning = Self.checkWatchdogAliveSync(appPID: appPID)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isKernelSleepDisabled != disabled {
                    self.isKernelSleepDisabled = disabled
                }
                self.isWatchdogAliveCached = watchdogRunning
                self.refreshClamshellStateLabels()
            }
        }
    }

    nonisolated private static func readKernelSleepDisabledSync() -> Bool {
        let pmTask = Process()
        pmTask.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmTask.arguments = ["-g"]
        let pmPipe = Pipe()
        pmTask.standardOutput = pmPipe
        pmTask.standardError = FileHandle.nullDevice
        guard (try? pmTask.run()) != nil else { return false }
        let data = pmPipe.fileHandleForReading.readDataToEndOfFile()
        pmTask.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SleepDisabled") && trimmed.hasSuffix("1") {
                return true
            }
        }
        return false
    }

    nonisolated private static func checkWatchdogAliveSync(appPID: pid_t) -> Bool {
        let pgTask = Process()
        pgTask.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgTask.arguments = ["-f", "clamshell_watchdog.sh \(appPID)"]
        pgTask.standardOutput = FileHandle.nullDevice
        pgTask.standardError = FileHandle.nullDevice
        guard (try? pgTask.run()) != nil else { return false }
        pgTask.waitUntilExit()
        return pgTask.terminationStatus == 0
    }

    private func refreshBatteryStatus() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let cap = desc[kIOPSCurrentCapacityKey] as? Int {
                batteryPercent = cap
            }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                isOnACPower = (state == kIOPSACPowerValue)
            }
        }
    }

    private func runNonBlockingCommand(_ path: String, args: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
        }
    }

    private func shellEscaped(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
