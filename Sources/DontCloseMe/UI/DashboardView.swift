import SwiftUI
import AppKit

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Monitor"
    case agents = "Watched Tools"
    case settings = "Settings"
    case logs = "Log"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .agents: return "terminal"
        case .settings: return "gearshape"
        case .logs: return "list.bullet"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var agentMonitor: AgentMonitor
    @ObservedObject var lidMonitor: LidSensorMonitor
    @ObservedObject var powerManager: PowerSleepManager
    @ObservedObject var alarmOverlay: AlarmOverlayController

    @State private var selectedTab: DashboardTab = .overview
    @State private var showingAddAgentSheet = false
    @State private var installStatusMessage: String? = nil

    var body: some View {
        NavigationSplitView {
            List(DashboardTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agentMonitor.isAnyAgentWorking ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(agentMonitor.isAnyAgentWorking ? "\(agentMonitor.workingAgents.count) Active" : "Idle")
                            .font(.caption.weight(.medium))
                    }
                    if let batt = powerManager.batteryPercent {
                        Text("Battery \(batt)% • \(powerManager.isOnACPower ? "AC" : "Unplugged")")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
        } detail: {
            Group {
                switch selectedTab {
                case .overview:
                    overviewTab
                case .agents:
                    agentsTab
                case .settings:
                    settingsTab
                case .logs:
                    logsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 620)
        .sheet(isPresented: $showingAddAgentSheet) {
            AddCustomAgentSheet { newProfile in
                settings.agentProfiles.append(newProfile)
                agentMonitor.scanNow()
            }
        }
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusHeaderCard

                HStack(alignment: .top, spacing: 14) {
                    lidAlarmControlCard
                    keepAwakeControlCard
                }

                liveAgentsSection
            }
            .padding(20)
        }
    }

    private var statusHeaderCard: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 11, height: 11)
                    Text(statusTitle)
                        .font(.title2.bold())
                }

                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Test Red Alarm") {
                        coordinator.triggerTestAlarm()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button(agentMonitor.manualSimulateWorking ? "Stop Simulation" : "Simulate Active Task") {
                        agentMonitor.manualSimulateWorking.toggle()
                    }
                    .buttonStyle(.bordered)

                    if alarmOverlay.isAlarmVisible {
                        Button("Stop Alarm") {
                            coordinator.dismissAlarm()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
                .padding(.top, 4)

                if let cooldown = agentMonitor.cooldownRemaining {
                    Text("Cooldown active: \(Int(ceil(cooldown)))s remaining before releasing guard.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            LidGaugeView(
                angle: lidMonitor.currentAngle,
                triggerAngle: settings.triggerAngleDegrees,
                isClamshellClosed: lidMonitor.isClamshellClosed,
                isAlarmActive: alarmOverlay.isAlarmVisible
            )
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var lidAlarmControlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Red Lid-Close Alarm")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $settings.lidAlarmEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.red)
            }

            Text(settings.lidAlarmEnabled
                 ? "Armed. Flashes full-screen red and alarms if the lid drops below \(Int(settings.triggerAngleDegrees))° during active work."
                 : "Off. Closing the lid will not trigger an alarm.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Trigger Angle")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(Int(settings.triggerAngleDegrees))°")
                        .font(.caption.monospacedDigit().bold())
                }
                Slider(value: $settings.triggerAngleDegrees, in: 45...105, step: 1)
                    .tint(.red)

                Toggle("Max Volume Override (ignores volume keys)", isOn: $settings.overrideSystemVolumeOnAlarm)
                    .font(.caption)
                Toggle("Spoken warning (\"Do not close me\")", isOn: $settings.voiceAlarmEnabled)
                    .font(.caption)
                Toggle("Loud klaxon siren", isOn: $settings.sirenSoundEnabled)
                    .font(.caption)
                Toggle("Rapid-slam detection", isOn: $settings.rapidCloseDetection)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(settings.lidAlarmEnabled ? Color.red.opacity(0.35) : Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var keepAwakeControlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keep Awake When Lid Closed")
                    .font(.headline)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { settings.keepAwakeWhenLidClosed },
                        set: { coordinator.toggleKeepAwakeWhenLidClosed($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Text(settings.keepAwakeWhenLidClosed
                 ? "Enabled. Keeps Mac running with the lid closed until active tools finish, then restores sleep."
                 : "Off. Standard macOS clamshell sleep applies.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    StatusTag(
                        text: powerManager.isStandardAssertionActive ? "Assertion: Active" : "Assertion: Idle",
                        isActive: powerManager.isStandardAssertionActive
                    )
                    StatusTag(
                        text: powerManager.isKernelSleepDisabled ? "pmset disablesleep: 1" : "pmset disablesleep: 0",
                        isActive: powerManager.isKernelSleepDisabled
                    )
                }

                Text(powerManager.clamshellAuthStatus.label)
                    .font(.caption2)
                    .foregroundStyle(powerManager.clamshellAuthStatus.isAuthorized ? .green : .secondary)

                if powerManager.clamshellAuthStatus.isAuthorizing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for Touch ID / password...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            powerManager.cancelAuthorization()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if !powerManager.clamshellAuthStatus.isAuthorized {
                    Button("Authorize Full Clamshell Mode (pmset)") {
                        settings.keepAwakeWhenLidClosed = true
                        powerManager.authorizeClamshellWatchdog()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Toggle("Flash red warning before lid shuts", isOn: $settings.warnBeforeHeadlessClose)
                    .font(.caption)
                Toggle("Sleep Mac when tasks finish (if lid closed)", isOn: $settings.autoSleepWhenAIFinishes)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var liveAgentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detected Tools & Agents")
                        .font(.headline)
                    Text("Watches Claude Code, Codex, OpenCode, Cursor, Antigravity, Aider, Windsurf, Copilot, Ollama, and custom tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Detection", selection: $settings.sensitivity) {
                    ForEach(DetectionSensitivity.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            if agentMonitor.workingAgents.isEmpty && agentMonitor.detectedAgents.isEmpty {
                HStack {
                    Text("No watched tools running right now. Launch Claude Code, Codex, OpenCode, or Cursor, or click Simulate Active Task.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 275), spacing: 12)], spacing: 12) {
                    if agentMonitor.manualSimulateWorking,
                       let sim = agentMonitor.workingAgents.first(where: { $0.id == "simulated-agent" }) {
                        AgentStatusCard(agent: sim, onTogglePin: nil)
                    }
                    ForEach(agentMonitor.detectedAgents) { agent in
                        AgentStatusCard(agent: agent) {
                            coordinator.toggleAlwaysGuard(profileID: agent.profile.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Watched Tools Tab

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watched Tools")
                        .font(.title2.bold())
                    Text("Enable/disable tools, pin tools to guard even when idle, or add custom processes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Defaults") {
                    settings.resetProfilesToDefault()
                }
                Button("Add Custom Tool") {
                    showingAddAgentSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding([.top, .horizontal], 20)

            List {
                ForEach($settings.agentProfiles) { $profile in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(profile.name)
                                    .font(.headline)
                                Text(profile.category.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                            }
                            Text("Match: \((profile.executableNames + profile.commandSubstrings).prefix(4).joined(separator: ", "))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Toggle("Always Guard", isOn: $profile.alwaysGuardWhenOpen)
                            .toggleStyle(.checkbox)
                            .font(.caption)

                        if !profile.isBuiltIn {
                            Button(role: .destructive) {
                                settings.agentProfiles.removeAll { $0.id == profile.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }

                        Toggle("", isOn: $profile.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        Form {
            Section("Activity Detection") {
                Picker("Mode", selection: $settings.sensitivity) {
                    ForEach(DetectionSensitivity.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Text(settings.sensitivity.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Finish Cooldown Grace")
                    Spacer()
                    Text("\(Int(settings.cooldownGraceSeconds))s")
                        .monospacedDigit()
                }
                Slider(value: $settings.cooldownGraceSeconds, in: 5...60, step: 5)
            }

            Section("Alarm Sound & Message") {
                Toggle("Force 100% System Volume During Alarm (Ignores Volume Keys)", isOn: $settings.overrideSystemVolumeOnAlarm)
                TextField("Custom alert message ({AGENT}, {ANGLE})", text: $settings.customJokeMessage)
                Text("Leave blank to cycle through built-in lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Battery Safety") {
                Stepper(
                    "Stop Keeping Awake Below \(settings.batterySafetyFloor)% Battery",
                    value: $settings.batterySafetyFloor,
                    in: 5...40,
                    step: 1
                )
            }

            Section("App") {
                Toggle("Show Dock Icon", isOn: $settings.showDockIcon)
                    .onChange(of: settings.showDockIcon) { _, show in
                        NSApp.setActivationPolicy(show ? .regular : .accessory)
                    }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy to /Applications")
                            .font(.subheadline.weight(.medium))
                        Text("Install DontCloseMe.app into /Applications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install") {
                        installBundleToApplications()
                    }
                    .buttonStyle(.bordered)
                }

                if let msg = installStatusMessage {
                    Text(msg)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    // MARK: - Logs Tab

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Event Log")
                    .font(.title2.bold())
                Spacer()
                Text("Alarms triggered: \(coordinator.totalSavedCloses)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding([.top, .horizontal], 20)

            List(coordinator.logs) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(colorForLog(item.level))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(item.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if alarmOverlay.isAlarmVisible { return .red }
        if agentMonitor.isAnyAgentWorking { return .green }
        return settings.lidAlarmEnabled ? .blue : .gray
    }

    private var statusTitle: String {
        if alarmOverlay.isAlarmVisible {
            return "ALARM ACTIVE — DO NOT CLOSE LID"
        }
        if agentMonitor.isAnyAgentWorking {
            if settings.keepAwakeWhenLidClosed {
                return "Keeping Mac Awake Until Tasks Finish"
            }
            return "Monitoring \(agentMonitor.workingAgents.count) Active Tool(s)"
        }
        return settings.lidAlarmEnabled ? "Armed — Ready" : "Guard Paused"
    }

    private var statusSubtitle: String {
        if alarmOverlay.isAlarmVisible {
            return "Lid angle dropped below threshold during active work."
        }
        if agentMonitor.isAnyAgentWorking {
            return "Active: " + agentMonitor.workingAgents.map { $0.profile.name }.joined(separator: ", ")
        }
        return lidMonitor.hasLidAngleSensor
            ? "MacBook lid sensor connected."
            : "Clamshell monitor connected."
    }

    private func colorForLog(_ level: ActivityLogEntry.Level) -> Color {
        switch level {
        case .alarm: return .red
        case .power: return .blue
        case .finished: return .green
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private func installBundleToApplications() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            installStatusMessage = "Run the packaged DontCloseMe.app bundle to install to /Applications."
            return
        }
        let destURL = URL(fileURLWithPath: "/Applications/DontCloseMe.app")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: bundleURL, to: destURL)
            installStatusMessage = "Installed to /Applications/DontCloseMe.app."
        } catch {
            installStatusMessage = "Failed: \(error.localizedDescription)"
        }
    }
}

private struct AgentStatusCard: View {
    let agent: DetectedAgent
    let onTogglePin: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle()
                    .fill(agent.state == .working ? Color.green : (agent.state == .cooldown ? Color.orange : Color.secondary.opacity(0.4)))
                    .frame(width: 8, height: 8)
                Text(agent.profile.name)
                    .font(.headline)
                Spacer()
                if let onTogglePin {
                    Button {
                        onTogglePin()
                    } label: {
                        Image(systemName: agent.profile.alwaysGuardWhenOpen ? "pin.fill" : "pin")
                            .font(.caption)
                            .foregroundStyle(agent.profile.alwaysGuardWhenOpen ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(agent.profile.alwaysGuardWhenOpen ? "Pinned: Always guarded even when idle" : "Pin to guard even when idle")
                }
                Text(agent.state.rawValue.uppercased())
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(agent.state.isGuarded ? .white : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        agent.state == .working
                            ? Color.green
                            : (agent.state == .cooldown ? Color.orange : Color.secondary.opacity(0.18)),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }

            HStack(spacing: 10) {
                Text(String(format: "CPU %.1f%%", agent.treeCPUPercent))
                Text("PID \(agent.pids.first ?? 0)")
                if agent.activeChildCount > 0 {
                    Text("\(agent.activeChildCount) child")
                }
                if let dur = agent.workingDurationText {
                    Text(dur)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if !agent.reasons.isEmpty {
                Text(agent.reasons.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else {
                Text(agent.sampleCommand)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(agent.state.isGuarded ? Color.green.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct StatusTag: View {
    let text: String
    let isActive: Bool

    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isActive ? Color.green.opacity(0.2) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct AddCustomAgentSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var executable = ""
    @State private var commandKeyword = ""
    @State private var watchedPath = ""
    @State private var category: AgentCategory = .custom

    let onAdd: (AgentProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Custom Tool")
                .font(.title3.bold())

            Form {
                TextField("Display Name", text: $name)
                Picker("Category", selection: $category) {
                    ForEach(AgentCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                TextField("Executable Name(s), comma-separated", text: $executable)
                TextField("Command Substring(s), optional", text: $commandKeyword)
                TextField("Watched Path(s), optional", text: $watchedPath)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let execs = splitCSV(executable)
                    let cmds = splitCSV(commandKeyword)
                    let paths = splitCSV(watchedPath)
                    let profile = AgentProfile(
                        id: "custom-\(UUID().uuidString.prefix(8))",
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        category: category,
                        executableNames: execs,
                        commandSubstrings: cmds,
                        watchedPaths: paths,
                        sfSymbol: "terminal",
                        accentHex: "#FF3B30",
                        isEnabled: true,
                        isBuiltIn: false
                    )
                    onAdd(profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (splitCSV(executable).isEmpty && splitCSV(commandKeyword).isEmpty)
                )
            }
        }
        .padding(18)
        .frame(width: 460, height: 340)
    }

    private func splitCSV(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
