import SwiftUI

enum MotionTheme {
    static let background = Color(red: 0.035, green: 0.05, blue: 0.09)
    static let panel = Color(red: 0.075, green: 0.095, blue: 0.145)
    static let accent = Color(red: 0.32, green: 0.91, blue: 0.77)
}

struct StatusPill: View {
    let text: String
    var active = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(active ? MotionTheme.accent : Color.secondary).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(.white.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct SensorCard: View {
    let title: String
    let value: MotionVector
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                axis("X", value.x, .cyan)
                Spacer()
                axis("Y", value.y, MotionTheme.accent)
                Spacer()
                axis("Z", value.z, .orange)
            }
        }.padding(16).background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 16))
    }
    private func axis(_ label: String, _ number: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(color)
            Text(number, format: .number.precision(.fractionLength(2)))
                .font(.system(.body, design: .monospaced)).monospacedDigit()
        }
    }
}

struct MovementReadout: View {
    let estimate: MotionEstimate
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MOVEMENT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(estimate.state).font(.caption2)
                    .foregroundStyle(estimate.isMoving ? MotionTheme.accent : .secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                metric("ACCELERATION", value: estimate.acceleration.magnitude, unit: "m/s²", color: .orange)
                Spacer()
                metric("EST. SPEED", value: estimate.speed, unit: "m/s", color: MotionTheme.accent)
            }
            Text(estimate.isAvailable ? estimate.directionLabel : "Waiting for motion data")
                .font(.headline).foregroundStyle(estimate.isMoving ? MotionTheme.accent : .secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(MotionDirection.allCases) { direction in
                    let active = estimate.strength(for: direction) > 0.35
                    VStack(spacing: 2) {
                        Text(direction.axisLabel).font(.caption2.bold())
                        Text(direction.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .foregroundStyle(active ? MotionTheme.accent : Color.secondary)
                    .background(active ? MotionTheme.accent.opacity(0.12) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("\(direction.title), \(active ? "active" : "inactive")")
                }
            }
            Text("Speed is a short-movement estimate. Hold still before resetting; constant-speed travel cannot be distinguished from rest.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func metric(_ title: String, value: Double, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if estimate.isAvailable {
                    Text(value, format: .number.precision(.fractionLength(2)))
                        .font(.system(.title2, design: .monospaced, weight: .semibold)).monospacedDigit()
                } else { Text("—").font(.title2) }
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }.foregroundStyle(color)
        }
    }
}
