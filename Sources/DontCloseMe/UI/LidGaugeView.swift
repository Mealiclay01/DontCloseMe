import SwiftUI

struct LidGaugeView: View {
    let angle: Double?
    let triggerAngle: Double
    let isClamshellClosed: Bool
    let isAlarmActive: Bool

    private var effectiveAngle: Double {
        if isClamshellClosed { return 0 }
        return angle ?? 115
    }

    private var isDangerZone: Bool {
        isClamshellClosed || effectiveAngle <= triggerAngle
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Danger arc from 0° up to triggerAngle
                ArcShape(startDegrees: 0, endDegrees: min(145, triggerAngle))
                    .stroke(Color.red.opacity(0.32), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 120, height: 120)

                // Safe arc
                ArcShape(startDegrees: min(145, triggerAngle), endDegrees: 140)
                    .stroke(Color.green.opacity(0.28), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 120, height: 120)

                // MacBook stylized side-profile
                Canvas { context, size in
                    let hinge = CGPoint(x: size.width * 0.54, y: size.height * 0.72)
                    let baseLen: CGFloat = 56
                    let lidLen: CGFloat = 58

                    // Base deck
                    var basePath = Path()
                    basePath.move(to: hinge)
                    basePath.addLine(to: CGPoint(x: hinge.x - baseLen, y: hinge.y))
                    context.stroke(
                        basePath,
                        with: .color(.secondary.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )

                    // Lid tilted by effectiveAngle (0 = shut flat left, 90 = vertical up, >90 = opened back)
                    let rad = effectiveAngle * .pi / 180.0
                    let tip = CGPoint(
                        x: hinge.x - lidLen * cos(rad),
                        y: hinge.y - lidLen * sin(rad)
                    )
                    var lidPath = Path()
                    lidPath.move(to: hinge)
                    lidPath.addLine(to: tip)
                    let lidColor: Color = isAlarmActive || isDangerZone ? .red : .accentColor
                    context.stroke(
                        lidPath,
                        with: .color(lidColor),
                        style: StrokeStyle(lineWidth: 5.5, lineCap: .round)
                    )

                    // Hinge dot
                    let dotRect = CGRect(x: hinge.x - 4.5, y: hinge.y - 4.5, width: 9, height: 9)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.primary))
                }
                .frame(width: 130, height: 110)
            }

            HStack(spacing: 6) {
                if let angle {
                    Text("\(Int(angle.rounded()))°")
                        .font(.system(size: 20, weight: .heavy, design: .monospaced))
                        .foregroundStyle(isDangerZone ? .red : .primary)
                } else {
                    Text(isClamshellClosed ? "CLOSED" : "NO SENSOR")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(isClamshellClosed ? .red : .secondary)
                }

                Text("•")
                    .foregroundStyle(.secondary)

                Text(isClamshellClosed ? "Shut" : (isDangerZone ? "Danger < \(Int(triggerAngle))°" : "Open Safe"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDangerZone ? .red : .green)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDangerZone ? Color.red.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct ArcShape: Shape {
    let startDegrees: Double
    let endDegrees: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY - 18)
        let radius = min(rect.width, rect.height) * 0.45
        // Map 0° (left, 180° in SwiftUI coords) clockwise through 90° (top, 270°) to 145°
        let s = Angle.degrees(180 + startDegrees)
        let e = Angle.degrees(180 + endDegrees)
        path.addArc(center: center, radius: radius, startAngle: s, endAngle: e, clockwise: false)
        return path
    }
}
