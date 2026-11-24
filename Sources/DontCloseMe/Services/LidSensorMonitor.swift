import Foundation
import AppKit
import IOKit
import IOKit.hid

@MainActor
final class LidSensorMonitor: ObservableObject {
    @Published private(set) var hasLidAngleSensor: Bool = false
    @Published private(set) var currentAngle: Double? = nil
    @Published private(set) var angularVelocityDegPerSec: Double = 0
    @Published private(set) var isClamshellClosed: Bool = false
    @Published private(set) var clamshellCausesSleep: Bool = true
    @Published private(set) var isClosingTriggerActive: Bool = false
    @Published private(set) var lastTriggerReason: String? = nil

    var onClosingAttemptDetected: ((Double?, String) -> Void)?
    var onLidReopened: (() -> Void)?
    var onSystemWillSleep: (() -> Void)?

    private var hidManager: IOHIDManager?
    private var lidDevice: IOHIDDevice?
    private var rootDomainService: io_service_t = 0
    private var pollTimer: Timer?
    private var currentInterval: TimeInterval = 0.25

    private var angleHistory: [(date: Date, angle: Double)] = []
    private var baselineOpenAngle: Double = 115.0
    private var isArmedFastPoll: Bool = false
    private var lastTriggerDate: Date = .distantPast
    private var workspaceObservers: [NSObjectProtocol] = []

    private weak var settings: AppSettings?

    init(settings: AppSettings) {
        self.settings = settings
        setupHID()
        setupRootDomain()
        setupWorkspaceNotifications()
        sampleOnce()
        scheduleTimer(interval: 0.25)
    }

    deinit {
        pollTimer?.invalidate()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let dev = lidDevice {
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let mgr = hidManager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if rootDomainService != 0 {
            IOObjectRelease(rootDomainService)
        }
    }

    func setHighFrequencyPolling(_ enabled: Bool) {
        guard isArmedFastPoll != enabled else { return }
        isArmedFastPoll = enabled
        scheduleTimer(interval: enabled ? 0.12 : 0.45)
    }

    func refreshHardwareConnection() {
        if lidDevice == nil {
            setupHID()
        }
        sampleOnce()
    }

    private func setupHID() {
        if let dev = lidDevice {
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            lidDevice = nil
        }
        if let mgr = hidManager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            hasLidAngleSensor = false
            return
        }
        hidManager = mgr

        guard let cfDevices = IOHIDManagerCopyDevices(mgr),
              let devices = (cfDevices as NSSet).allObjects as? [IOHIDDevice] else {
            hasLidAngleSensor = false
            return
        }

        for device in devices {
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            if usagePage == 0x0020 && usage == 0x008A {
                if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                    lidDevice = device
                    hasLidAngleSensor = true
                    break
                }
            }
        }
    }

    private func setupRootDomain() {
        rootDomainService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
    }

    private func setupWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        let willSleep = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onSystemWillSleep?()
            }
        }
        let screensSleep = nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sampleOnce()
            }
        }
        let didWake = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshHardwareConnection()
            }
        }
        workspaceObservers = [willSleep, screensSleep, didWake]
    }

    private func scheduleTimer(interval: TimeInterval) {
        if let existing = pollTimer, abs(existing.timeInterval - interval) < 0.01 {
            return
        }
        pollTimer?.invalidate()
        currentInterval = interval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleOnce()
            }
        }
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func sampleOnce() {
        readClamshellRegistryState()
        let angle = readLidAngleDegrees()
        let now = Date()

        if let angle {
            if currentAngle == nil || abs((currentAngle ?? 0) - angle) >= 0.5 {
                currentAngle = angle
            }
            angleHistory.append((now, angle))
            angleHistory.removeAll { now.timeIntervalSince($0.date) > 0.7 }

            if angle > 95 && abs(angularVelocityDegPerSec) < 8 {
                baselineOpenAngle = baselineOpenAngle * 0.92 + angle * 0.08
            }

            let newVelocity: Double
            if let oldest = angleHistory.first {
                let dt = now.timeIntervalSince(oldest.date)
                newVelocity = dt >= 0.08 ? (angle - oldest.angle) / dt : 0
            } else {
                newVelocity = 0
            }
            let quantizedVel = abs(newVelocity) < 2.0 ? 0.0 : newVelocity
            if abs(angularVelocityDegPerSec - quantizedVel) >= 2.0 {
                angularVelocityDegPerSec = quantizedVel
            }
        } else {
            if currentAngle != nil { currentAngle = nil }
            if angularVelocityDegPerSec != 0 { angularVelocityDegPerSec = 0 }
        }

        evaluateTrigger(angle: angle, now: now)
    }

    private func readLidAngleDegrees() -> Double? {
        guard let device = lidDevice else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        let kr = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard kr == kIOReturnSuccess, length >= 3 else {
            return nil
        }
        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        let degrees = Double(raw)
        if degrees < 0 || degrees > 200 {
            return nil
        }
        return degrees
    }

    private func readClamshellRegistryState() {
        guard rootDomainService != 0 else { return }
        if let cs = IORegistryEntryCreateCFProperty(
            rootDomainService,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool, cs != isClamshellClosed {
            isClamshellClosed = cs
        }
        if let ccs = IORegistryEntryCreateCFProperty(
            rootDomainService,
            "AppleClamshellCausesSleep" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool, ccs != clamshellCausesSleep {
            clamshellCausesSleep = ccs
        }
    }

    private func evaluateTrigger(angle: Double?, now: Date) {
        let triggerThreshold = settings?.triggerAngleDegrees ?? 85.0
        let rapidEnabled = settings?.rapidCloseDetection ?? true

        var shouldTrigger = false
        var reason = ""

        if isClamshellClosed {
            shouldTrigger = true
            reason = "Clamshell closed"
        } else if let angle {
            let belowThreshold = angle <= triggerThreshold
            let rapidClosing = rapidEnabled
                && angularVelocityDegPerSec <= -20.0
                && angle < min(108.0, baselineOpenAngle - 10.0)

            if belowThreshold {
                shouldTrigger = true
                reason = "Lid angle dropped to \(Int(angle.rounded()))° (below \(Int(triggerThreshold))°)"
            } else if rapidClosing {
                shouldTrigger = true
                reason = "Rapid lid-closing motion at \(Int(angle.rounded()))°"
            }
        }

        if shouldTrigger {
            lastTriggerReason = reason
            if !isClosingTriggerActive {
                isClosingTriggerActive = true
                if now.timeIntervalSince(lastTriggerDate) > 0.6 {
                    lastTriggerDate = now
                    onClosingAttemptDetected?(angle, reason)
                }
            }
        } else {
            // Apply +8° hysteresis so minor hand jitter doesn't flicker the alarm
            let reopenClear = !isClamshellClosed && (angle == nil || (angle ?? 120) >= triggerThreshold + 8.0)
            if isClosingTriggerActive && reopenClear {
                isClosingTriggerActive = false
                lastTriggerReason = nil
                onLidReopened?()
            }
        }
    }
}
