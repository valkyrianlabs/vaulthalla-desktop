import SwiftUI

/// A status color. Only the backend decides which tone applies; a missing or unrecognized severity is `.unknown`,
/// which is never green.
enum StatusTone: String, CaseIterable, Hashable, Sendable {
    case ok, info, warn, danger, unknown

    /// Maps a daemon severity or component status to its tone, mirroring the web console's `severityTone`.
    init(severity: String?) {
        switch severity?.lowercased() {
        case "healthy", "ok", "idle", "normal", "ready": self = .ok
        case "info", "syncing", "success": self = .info
        case "warning", "warn", "degraded", "pressured", "stale": self = .warn
        case "error", "critical", "failed", "saturated", "failing", "stalled", "diverged", "overdue": self = .danger
        default: self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .ok: Color(.sRGB, red: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255)
        case .info: Color(.sRGB, red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)
        case .warn: Color(.sRGB, red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
        case .danger: Color(.sRGB, red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255)
        case .unknown: Color(.sRGB, red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255)
        }
    }

    var soft: Color { color.opacity(0.12) }

    var line: Color {
        switch self {
        case .ok, .info: color.opacity(0.34)
        case .warn: color.opacity(0.36)
        case .danger: color.opacity(0.38)
        case .unknown: color.opacity(0.3)
        }
    }
}

/// The small round status indicator used in lists. `pulse` marks a transitional state (connecting).
struct StatusDot: View {
    var tone: StatusTone
    var size: CGFloat = 8
    var pulse = false

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .background {
                if pulse && !reduceMotion {
                    Circle()
                        .fill(tone.color.opacity(expanded ? 0 : 0.6))
                        .scaleEffect(expanded ? 2.4 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: expanded)
                        .onAppear { expanded = true }
                }
            }
            .accessibilityHidden(true)
    }
}

/// A pill with a dot and a label, tinted by its tone (the web's `Badge` with `dot`).
struct StatusBadge: View {
    var label: String
    var tone: StatusTone
    var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: tone, size: 6, pulse: pulse)
            Text(label)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(tone.soft, in: Capsule())
        .overlay { Capsule().strokeBorder(tone.line, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}
