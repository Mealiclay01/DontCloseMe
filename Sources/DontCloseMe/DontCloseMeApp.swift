import SwiftUI
import AppKit
import Combine

@main
struct DontCloseMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var coordinator: AppCoordinator!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var dashboardWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()

        let policy: NSApplication.ActivationPolicy = coordinator.settings.showDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)

        setupMenuBar()
        observeMenuBarIconState()
        openDashboardWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openDashboardWindow()
        } else {
            dashboardWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in Menu Bar even when Dashboard window is closed
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.cleanupBeforeTermination()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                coordinator: coordinator,
                settings: coordinator.settings,
                agentMonitor: coordinator.agentMonitor,
                lidMonitor: coordinator.lidMonitor,
                powerManager: coordinator.powerManager,
                alarmOverlay: coordinator.alarmOverlay,
                onOpenDashboard: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openDashboardWindow()
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
        popover = pop
        updateMenuBarAppearance()
    }

    private func observeMenuBarIconState() {
        Publishers.CombineLatest4(
            coordinator.agentMonitor.$isAnyAgentWorking,
            coordinator.settings.$lidAlarmEnabled,
            coordinator.settings.$keepAwakeWhenLidClosed,
            coordinator.alarmOverlay.$isAlarmVisible
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            self?.updateMenuBarAppearance()
        }
        .store(in: &cancellables)
    }

    private func updateMenuBarAppearance() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let titleSuffix: String
        if coordinator.alarmOverlay.isAlarmVisible {
            symbolName = "exclamationmark.triangle.fill"
            titleSuffix = " STOP!"
        } else if coordinator.agentMonitor.isAnyAgentWorking {
            symbolName = coordinator.settings.keepAwakeWhenLidClosed
                ? "bolt.shield.fill"
                : "shield.checkered"
            titleSuffix = " \(coordinator.agentMonitor.workingAgents.count)"
        } else if coordinator.settings.lidAlarmEnabled {
            symbolName = "shield.lefthalf.filled"
            titleSuffix = ""
        } else {
            symbolName = "shield.slash"
            titleSuffix = ""
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DontCloseMe")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
        button.image = img
        button.title = titleSuffix
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func openDashboardWindow() {
        if let existing = dashboardWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = DashboardView(
            coordinator: coordinator,
            settings: coordinator.settings,
            agentMonitor: coordinator.agentMonitor,
            lidMonitor: coordinator.lidMonitor,
            powerManager: coordinator.powerManager,
            alarmOverlay: coordinator.alarmOverlay
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DontCloseMe"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        dashboardWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
