import Foundation
import AppKit
import SwiftUI

@MainActor
final class AlarmOverlayController: ObservableObject {
    @Published private(set) var isAlarmVisible: Bool = false

    private let overlayState = AlarmOverlayState()
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var phraseRotationTimer: Timer?
    private var currentPhraseIndex: Int = 0
    private var snoozeUntil: Date = .distantPast
    private var customPhrase: String = ""

    private var onDismissCallback: (() -> Void)?
    private var onSnoozeCallback: (() -> Void)?

    var isSnoozed: Bool {
        Date() < snoozeUntil
    }

    var snoozeSecondsRemaining: Int {
        max(0, Int(ceil(snoozeUntil.timeIntervalSinceNow)))
    }

    func showAlarm(
        agents: [DetectedAgent],
        angle: Double?,
        triggerThreshold: Double,
        isHeadlessWarning: Bool,
        customPhrase: String,
        onDismiss: @escaping () -> Void,
        onSnooze: @escaping () -> Void
    ) {
        self.customPhrase = customPhrase
        self.onDismissCallback = onDismiss
        self.onSnoozeCallback = onSnooze

        overlayState.agents = agents
        overlayState.currentAngle = angle
        overlayState.triggerThreshold = triggerThreshold
        overlayState.isClamshellHeadlessWarning = isHeadlessWarning

        if isAlarmVisible {
            updateJokeText()
            return
        }

        isAlarmVisible = true
        currentPhraseIndex = Int.random(in: 0..<JokePhraseBank.defaultPhrases.count)
        updateJokeText()
        createWindows()
        installEscapeMonitor()
        startPhraseRotation()
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLiveTelemetry(agents: [DetectedAgent], angle: Double?, triggerThreshold: Double) {
        guard isAlarmVisible else { return }
        overlayState.agents = agents
        overlayState.currentAngle = angle
        overlayState.triggerThreshold = triggerThreshold
    }

    func snooze(seconds: TimeInterval = 60) {
        snoozeUntil = Date().addingTimeInterval(seconds)
        hideAlarm()
        onSnoozeCallback?()
    }

    func clearSnooze() {
        snoozeUntil = .distantPast
    }

    func hideAlarm() {
        guard isAlarmVisible || !windows.isEmpty else { return }
        isAlarmVisible = false
        phraseRotationTimer?.invalidate()
        phraseRotationTimer = nil

        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }

        for win in windows {
            win.orderOut(nil)
            win.close()
        }
        windows.removeAll()
    }

    private func createWindows() {
        for (index, screen) in NSScreen.screens.enumerated() {
            let win = KeyableAlarmWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .screenSaver
            win.backgroundColor = .clear
            win.isOpaque = false
            win.hasShadow = false
            win.ignoresMouseEvents = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            win.isReleasedWhenClosed = false
            win.setFrame(screen.frame, display: true)
            win.contentView = NSHostingView(
                rootView: AlarmOverlayView(
                    state: overlayState,
                    onDismiss: { [weak self] in
                        self?.hideAlarm()
                        self?.onDismissCallback?()
                    },
                    onSnooze: { [weak self] in
                        self?.snooze(seconds: 60)
                    }
                )
            )
            if index == 0 {
                win.makeKeyAndOrderFront(nil)
            } else {
                win.orderFrontRegardless()
            }
            windows.append(win)
        }
    }

    private func updateJokeText() {
        let trimmedCustom = customPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let template: String
        if !trimmedCustom.isEmpty && currentPhraseIndex % 2 == 0 {
            template = trimmedCustom
        } else {
            template = JokePhraseBank.defaultPhrases[currentPhraseIndex % JokePhraseBank.defaultPhrases.count]
        }
        overlayState.jokeMessage = JokePhraseBank.format(
            template,
            agents: overlayState.agents,
            angle: overlayState.currentAngle
        )
    }

    private func startPhraseRotation() {
        phraseRotationTimer?.invalidate()
        phraseRotationTimer = Timer.scheduledTimer(withTimeInterval: 3.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAlarmVisible else { return }
                self.currentPhraseIndex += 1
                self.updateJokeText()
            }
        }
        if let phraseRotationTimer {
            RunLoop.main.add(phraseRotationTimer, forMode: .common)
        }
    }

    private func installEscapeMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.hideAlarm()
                    self?.onDismissCallback?()
                }
                return nil
            }
            return event
        }
    }
}

private final class KeyableAlarmWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
