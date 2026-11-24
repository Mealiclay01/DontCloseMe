import SwiftUI

@MainActor
final class AlarmOverlayState: ObservableObject {
    @Published var agents: [DetectedAgent] = []
    @Published var currentAngle: Double? = nil
    @Published var triggerThreshold: Double = 85.0
    @Published var headline: String = "STOP. DO NOT CLOSE ME."
    @Published var jokeMessage: String = "I'M STILL WORKING."
    @Published var isClamshellHeadlessWarning: Bool = false
}

struct AlarmOverlayView: View {
    @ObservedObject var state: AlarmOverlayState
    let onDismiss: () -> Void
    let onSnooze: () -> Void

    @State private var strobe = false

    var body: some View {
        ZStack {
            // Sharp full-screen red alert backdrop
            Color(red: strobe ? 0.78 : 0.45, green: 0.02, blue: 0.03)
                .opacity(0.95)
                .ignoresSafeArea()

            // Edge danger border
            Rectangle()
                .strokeBorder(
                    strobe ? Color(red: 1.0, green: 0.15, blue: 0.15) : Color.white.opacity(0.85),
                    lineWidth: 12
                )
                .ignoresSafeArea()

            VStack(spacing: 28) {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 56, weight: .black))
                        .foregroundStyle(strobe ? .white : .yellow)
                    Text("ALERT")
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }

                VStack(spacing: 12) {
                    Text(state.headline)
                        .font(.system(size: 58, weight: .black))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("I'M WORKING RIGHT NOW.")
                        .font(.system(size: 28, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))

                    Text(state.jokeMessage)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.94, blue: 0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
                }

                if state.isClamshellHeadlessWarning {
                    Text("Keep-Awake When Closed is ON — keep ventilation clear if you close the lid.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                }

                if !state.agents.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(state.agents.prefix(4)) { agent in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 7, height: 7)
                                Text(agent.profile.name)
                                    .font(.system(size: 14, weight: .bold))
                                if !agent.reasons.isEmpty {
                                    Text(agent.reasons[0])
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }
                }

                if let angle = state.currentAngle {
                    VStack(spacing: 6) {
                        HStack {
                            Text("LID ANGLE: \(Int(angle.rounded()))°")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("OPEN ABOVE \(Int((state.triggerThreshold + 8).rounded()))° TO CLEAR")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        GeometryReader { geo in
                            let ratio = min(max(angle / 135.0, 0), 1)
                            let threshRatio = min(max(state.triggerThreshold / 135.0, 0), 1)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.5))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(angle <= state.triggerThreshold ? Color.white : Color.green)
                                    .frame(width: geo.size.width * ratio)
                                Rectangle()
                                    .fill(Color.yellow)
                                    .frame(width: 3)
                                    .offset(x: geo.size.width * threshRatio)
                            }
                        }
                        .frame(height: 14)
                    }
                    .frame(maxWidth: 460)
                    .padding(14)
                    .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 14) {
                    Button(action: onDismiss) {
                        Text("Stop Alarm (Esc)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(red: 0.75, green: 0.02, blue: 0.03))
                            .padding(.horizontal, 26)
                            .padding(.vertical, 12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button(action: onSnooze) {
                        Text("Snooze 60s")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(44)
            .frame(maxWidth: 820)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)) {
                strobe = true
            }
        }
    }
}
