import Foundation
import Combine
import AppKit
import UserNotifications

@MainActor
final class AppCoordinator: ObservableObject {
    let settings: AppSettings
    let lidMonitor: LidSensorMonitor
    let agentMonitor: AgentMonitor
    let powerManager: PowerSleepManager
    let alarmOverlay: AlarmOverlayController
    let voicePlayer: VoiceAlarmPlayer

    @Published private(set) var logs: [ActivityLogEntry] = []
    @Published private(set) var totalSavedCloses: Int = 0
    @Published var isTestAlarmActive: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.lidMonitor = LidSensorMonitor(settings: settings)
        self.agentMonitor = AgentMonitor(settings: settings)
        self.powerManager = PowerSleepManager()
        self.alarmOverlay = AlarmOverlayController()
        self.voicePlayer = VoiceAlarmPlayer()

        requestNotificationPermissionIfBundled()
        wireCallbacks()
        wireStateBindings()

        addLog(.info, title: "DontCloseMe Started", detail: "Monitoring lid sensor and running processes.")
    }

    func toggleKeepAwakeWhenLidClosed(_ newValue: Bool) {
        settings.keepAwakeWhenLidClosed = newValue
        syncPowerPolicy()

        if newValue {
            addLog(
                .power,
                title: "Lid-Closed Work Mode Enabled",
                detail: "Mac will stay awake until active agents finish."
            )
            if !powerManager.clamshellAuthStatus.isAuthorized {
                powerManager.authorizeClamshellWatchdog()
            }
        } else {
            if powerManager.clamshellAuthStatus.isAuthorizing {
                powerManager.cancelAuthorization()
            }
            addLog(
                .power,
                title: "Lid-Closed Work Mode Disabled",
                detail: "Standard macOS lid sleep behavior restored."
            )
        }
    }

    func toggleAlwaysGuard(profileID: String) {
        guard let idx = settings.agentProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        settings.agentProfiles[idx].alwaysGuardWhenOpen.toggle()
        agentMonitor.scanNow()
    }

    func triggerTestAlarm() {
        isTestAlarmActive = true
        alarmOverlay.clearSnooze()
        let demoAgents = agentMonitor.workingAgents.isEmpty
            ? [
                DetectedAgent(
                    profile: AgentProfile.builtInDefaults[0],
                    pids: [9999],
                    sampleCommand: "claude",
                    treeCPUPercent: 47.2,
                    activeChildCount: 2,
                    hasRecentFileActivity: true,
                    hasActiveNetworkSocket: true,
                    state: .working,
                    reasons: ["Manual Test"],
                    lastActiveAt: Date(),
                    workingSince: Date()
                )
            ]
            : agentMonitor.workingAgents

        startAlarmUIAndAudio(
            agents: demoAgents,
            angle: lidMonitor.currentAngle ?? 72.0,
            isHeadlessWarning: settings.keepAwakeWhenLidClosed,
            reason: "Manual Test Alarm"
        )
    }

    func dismissAlarm() {
        isTestAlarmActive = false
        alarmOverlay.hideAlarm()
        voicePlayer.stop()
        addLog(.info, title: "Alarm Dismissed", detail: "System volume restored.")
    }

    func snoozeAlarm() {
        isTestAlarmActive = false
        alarmOverlay.snooze(seconds: 60)
        voicePlayer.stop()
        addLog(.info, title: "Alarm Snoozed (60s)", detail: "Warnings paused for 60 seconds.")
    }

    func cleanupBeforeTermination() {
        voicePlayer.stop()
        alarmOverlay.hideAlarm()
        powerManager.shutdownForAppTermination()
    }

    private func wireCallbacks() {
        lidMonitor.onClosingAttemptDetected = { [weak self] angle, reason in
            self?.handleClosingAttempt(angle: angle, reason: reason)
        }

        lidMonitor.onLidReopened = { [weak self] in
            guard let self else { return }
            if self.alarmOverlay.isAlarmVisible && !self.isTestAlarmActive {
                self.alarmOverlay.hideAlarm()
                self.voicePlayer.stop()
                self.addLog(
                    .info,
                    title: "Lid Reopened",
                    detail: "Back above threshold angle."
                )
            }
        }

        lidMonitor.onSystemWillSleep = { [weak self] in
            guard let self else { return }
            if self.agentMonitor.isAnyAgentWorking && self.settings.lidAlarmEnabled {
                self.sendUrgentNotification(
                    title: "STOP — Sleep Interrupted Active Work",
                    body: "Your Mac went to sleep while \(self.agentSummaryText()) was running."
                )
            }
            self.voicePlayer.stop()
            self.alarmOverlay.hideAlarm()
        }

        agentMonitor.onWorkingStarted = { [weak self] in
            guard let self else { return }
            self.addLog(
                .info,
                title: "Active Work Detected",
                detail: self.agentSummaryText()
            )
            self.syncPowerPolicy()
        }

        agentMonitor.onAllAgentsFinished = { [weak self] in
            guard let self else { return }
            self.addLog(
                .finished,
                title: "All Agents Finished",
                detail: self.settings.keepAwakeWhenLidClosed
                    ? "Released sleep lock."
                    : "Returned to standby."
            )
            if self.alarmOverlay.isAlarmVisible && !self.isTestAlarmActive {
                self.alarmOverlay.hideAlarm()
                self.voicePlayer.stop()
            }

            let lidClosed = self.lidMonitor.isClamshellClosed
            if self.settings.keepAwakeWhenLidClosed {
                self.powerManager.finishAndMaybeSleep(
                    isLidClosed: lidClosed,
                    autoSleepWhenDone: self.settings.autoSleepWhenAIFinishes,
                    batteryFloor: self.settings.batterySafetyFloor
                )
                self.sendUrgentNotification(
                    title: "Work Complete",
                    body: lidClosed && self.settings.autoSleepWhenAIFinishes
                        ? "All tasks finished. Putting Mac to sleep."
                        : "All tasks finished. Sleep guard released."
                )
                if !lidClosed && self.settings.voiceAlarmEnabled {
                    self.voicePlayer.playTaskCompleteChime()
                }
            } else {
                self.syncPowerPolicy()
            }
        }
    }

    private func wireStateBindings() {
        Publishers.CombineLatest3(
            agentMonitor.$isAnyAgentWorking,
            settings.$lidAlarmEnabled,
            alarmOverlay.$isAlarmVisible
        )
        .sink { [weak self] working, armed, alarmVisible in
            guard let self else { return }
            self.lidMonitor.setHighFrequencyPolling((working && armed) || alarmVisible)
            self.syncPowerPolicy()
        }
        .store(in: &cancellables)

        Publishers.CombineLatest(lidMonitor.$currentAngle, agentMonitor.$detectedAgents)
            .sink { [weak self] angle, _ in
                guard let self else { return }
                if self.alarmOverlay.isAlarmVisible {
                    self.alarmOverlay.updateLiveTelemetry(
                        agents: self.agentMonitor.workingAgents,
                        angle: angle,
                        triggerThreshold: self.settings.triggerAngleDegrees
                    )
                }
            }
            .store(in: &cancellables)

        lidMonitor.$isClamshellClosed
            .removeDuplicates()
            .sink { [weak self] closed in
                guard let self else { return }
                if closed && self.settings.keepAwakeWhenLidClosed && self.agentMonitor.isAnyAgentWorking {
                    self.voicePlayer.stop()
                    self.alarmOverlay.hideAlarm()
                    self.addLog(
                        .power,
                        title: "Lid Closed — Staying Awake",
                        detail: "Keeping Mac awake for \(self.agentSummaryText()) until finished."
                    )
                }
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncPowerPolicy()
            }
            .store(in: &cancellables)
    }

    private func syncPowerPolicy() {
        powerManager.updatePowerPolicy(
            keepAwakeEnabled: settings.keepAwakeWhenLidClosed,
            isAnyAgentWorking: agentMonitor.isAnyAgentWorking,
            batteryFloor: settings.batterySafetyFloor
        )
    }

    private func handleClosingAttempt(angle: Double?, reason: String) {
        guard settings.lidAlarmEnabled else { return }
        guard agentMonitor.isAnyAgentWorking else { return }
        guard !alarmOverlay.isSnoozed else { return }

        if settings.keepAwakeWhenLidClosed && !settings.warnBeforeHeadlessClose {
            return
        }
        if settings.keepAwakeWhenLidClosed && lidMonitor.isClamshellClosed {
            return
        }

        totalSavedCloses += 1
        startAlarmUIAndAudio(
            agents: agentMonitor.workingAgents,
            angle: angle,
            isHeadlessWarning: settings.keepAwakeWhenLidClosed,
            reason: reason
        )
    }

    private func startAlarmUIAndAudio(
        agents: [DetectedAgent],
        angle: Double?,
        isHeadlessWarning: Bool,
        reason: String
    ) {
        addLog(.alarm, title: "LID ALARM TRIGGERED", detail: "\(reason) • \(agentSummaryText())")

        alarmOverlay.showAlarm(
            agents: agents,
            angle: angle,
            triggerThreshold: settings.triggerAngleDegrees,
            isHeadlessWarning: isHeadlessWarning,
            customPhrase: settings.customJokeMessage,
            onDismiss: { [weak self] in
                self?.dismissAlarm()
            },
            onSnooze: { [weak self] in
                self?.snoozeAlarm()
            }
        )

        if settings.sirenSoundEnabled || settings.voiceAlarmEnabled {
            voicePlayer.startAlarm(
                agents: agents,
                angle: angle,
                playSiren: settings.sirenSoundEnabled,
                speakJoke: settings.voiceAlarmEnabled,
                overrideVolume: settings.overrideSystemVolumeOnAlarm,
                customPhrase: settings.customJokeMessage
            )
        }

        if lidMonitor.isClamshellClosed {
            sendUrgentNotification(
                title: "STOP — DO NOT CLOSE ME",
                body: "Active: \(agentSummaryText())"
            )
        }
    }

    private func agentSummaryText() -> String {
        let names = agentMonitor.workingAgents.map { $0.profile.name }
        if names.isEmpty { return "Active process" }
        return names.joined(separator: ", ")
    }

    private func addLog(_ level: ActivityLogEntry.Level, title: String, detail: String) {
        let entry = ActivityLogEntry(timestamp: Date(), level: level, title: title, detail: detail)
        logs.insert(entry, at: 0)
        if logs.count > 120 {
            logs.removeLast(logs.count - 120)
        }
    }

    private func requestNotificationPermissionIfBundled() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendUrgentNotification(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
