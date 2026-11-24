import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var agentMonitor: AgentMonitor
    @ObservedObject var lidMonitor: LidSensorMonitor
    @ObservedObject var powerManager: PowerSleepManager
    @ObservedObject var alarmOverlay: AlarmOverlayController

    let onOpenDashboard: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text("DontCloseMe")
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let angle = lidMonitor.currentAngle {
                    Text("\(Int(angle.rounded()))°")
                        .font(.system(.callout, design: .monospaced).bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()

            VStack(spacing: 8) {
                Toggle(isOn: $settings.lidAlarmEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lid-Close Red Alarm")
                            .font(.subheadline.weight(.medium))
                        Text("Alert below \(Int(settings.triggerAngleDegrees))° while active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(
                    isOn: Binding(
                        get: { settings.keepAwakeWhenLidClosed },
                        set: { coordinator.toggleKeepAwakeWhenLidClosed($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep Awake If Lid Closed")
                            .font(.subheadline.weight(.medium))
                        Text(powerManager.clamshellAuthStatus.isAuthorized
                             ? "Watchdog ready until tasks finish"
                             : "Keeps Mac awake until work completes")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("DETECTED PROCESSES")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let rem = agentMonitor.cooldownRemaining {
                        Text("Cooldown \(Int(ceil(rem)))s")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }

                let shown = agentMonitor.workingAgents.isEmpty
                    ? Array(agentMonitor.detectedAgents.prefix(5))
                    : Array(agentMonitor.workingAgents.prefix(5))

                if shown.isEmpty {
                    Text("No active tools detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                } else {
                    ForEach(shown) { agent in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(agent.state.isGuarded ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(agent.profile.name)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(agent.state.isGuarded ? String(format: "%.1f%%", agent.treeCPUPercent) : "Idle")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(agent.state.isGuarded ? .green : .secondary)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Test Alarm") {
                    coordinator.triggerTestAlarm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)

                Button(agentMonitor.manualSimulateWorking ? "Stop Sim" : "Simulate Work") {
                    agentMonitor.manualSimulateWorking.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }

            if alarmOverlay.isAlarmVisible {
                Button("Stop Active Alarm") {
                    coordinator.dismissAlarm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }

            HStack {
                Button("Open Window") {
                    onOpenDashboard()
                }
                .buttonStyle(.link)

                Spacer()

                Button("Quit") {
                    onQuit()
                }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var statusColor: Color {
        if alarmOverlay.isAlarmVisible { return .red }
        if agentMonitor.isAnyAgentWorking { return .green }
        if settings.lidAlarmEnabled { return .blue }
        return .gray
    }

    private var statusSubtitle: String {
        if alarmOverlay.isAlarmVisible { return "Alarm active" }
        if agentMonitor.isAnyAgentWorking {
            return "\(agentMonitor.workingAgents.count) active tool(s)"
        }
        return settings.lidAlarmEnabled ? "Armed — waiting for activity" : "Paused"
    }
}
