import Charts
import SwiftUI

/// One bar: a label, its value, and optionally the part of it that matters most (alertable errors of all errors).
struct BarItem: Identifiable {
    var id: String
    var label: String
    /// Secondary words after the label ("errno 2").
    var detail: String?
    var value: Double?
    var display: String
    /// The emphasized share of `value`, drawn in `emphasisTone` over the neutral bar.
    var emphasis: Double?
    var emphasisTone: StatusTone = .warn
    var help: String?
    var monospaced = false
}

/// Horizontal bars scaled to the largest value (the web's `BarList`). Values the daemon didn't report draw no bar.
struct BarList: View {
    var items: [BarItem]
    var empty = "Nothing recorded."
    /// Items that should stand out (the ones behind a warning).
    var highlighted: Set<String> = []

    var body: some View {
        if items.isEmpty {
            Text(empty)
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let peak = items.compactMap(\.value).max() ?? 0
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    BarRow(item: item, peak: peak, isHighlighted: highlighted.contains(item.id))
                }
            }
        }
    }
}

private struct BarRow: View {
    var item: BarItem
    var peak: Double
    var isHighlighted: Bool

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.label)
                    .fontDesign(item.monospaced ? .monospaced : .default)
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .foregroundStyle(.fgFaint)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(item.display)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.fg)
            }
            .font(.callout)
            GeometryReader { proxy in
                let full = proxy.size.width
                let share = peak > 0 ? (item.value ?? 0) / peak : 0
                let emphasis = (item.value ?? 0) > 0 ? min((item.emphasis ?? 0) / (item.value ?? 1), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surface2)
                    Capsule().fill(Color.accentFill.opacity(hovering ? 0.55 : 0.4))
                        .frame(width: max(full * share, (item.value ?? 0) > 0 ? 3 : 0))
                    if emphasis > 0 {
                        Capsule().fill(item.emphasisTone.color)
                            .frame(width: max(full * share * emphasis, 3))
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(item.emphasisTone.soft)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.display)
    }
}

/// A ring of parts with a figure in the middle (the web's `Donut`): hits and misses, sessions by kind.
struct DonutChart: View {
    struct Part: Identifiable {
        var label: String
        var value: Double?
        var color: Color
        var id: String { label }
    }

    var parts: [Part]
    var center: String
    var caption: String
    var label: String

    var body: some View {
        let measured = parts.filter { ($0.value ?? 0) > 0 }
        HStack(spacing: 18) {
            ZStack {
                if measured.isEmpty {
                    Circle().strokeBorder(Color.surface2, lineWidth: 14)
                } else {
                    Chart(measured) { part in
                        SectorMark(angle: .value(part.label, part.value ?? 0), innerRadius: .ratio(0.72),
                                   angularInset: 1.5)
                            .foregroundStyle(part.color)
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                }
                VStack(spacing: 0) {
                    Text(center)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.fg)
                        .minimumScaleFactor(0.7)
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.fgSubtle)
                }
                .padding(18)
            }
            .frame(width: 128, height: 128)
            .accessibilityLabel(label)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(parts) { part in
                    HStack(spacing: 7) {
                        Circle().fill(part.color).frame(width: 8, height: 8)
                        Text(part.label).foregroundStyle(.fgMuted)
                        Spacer(minLength: 8)
                        Text(part.value.map { Int64($0).formatted() } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(part.value == nil ? Color.fgFaint : Color.fg)
                    }
                    .font(.callout)
                }
            }
            .frame(minWidth: 140, maxWidth: 260)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A yes/no fact the daemon reported, with a dot; nil reads "not available" (the web's `Fact`).
struct FactLabel: View {
    var value: Bool?
    var yes = "Ready"
    var no = "Not ready"

    var body: some View {
        let tone: StatusTone = value == true ? .ok : value == false ? .danger : .unknown
        HStack(spacing: 6) {
            StatusDot(tone: tone, size: 6)
            Text(value == true ? yes : value == false ? no : "not available")
                .foregroundStyle(value == nil ? Color.fgFaint : Color.fg)
        }
    }
}

/// Facts in as many columns as fit: a label and its yes/no (or a neutral statement).
struct FactGrid: View {
    struct Fact: Identifiable {
        var label: String
        var value: Bool?
        var yes = "Ready"
        var no = "Not ready"
        /// Shown instead of yes/no: a statement, not a fact ("multiuser: mounted").
        var statement: String?
        /// Set when the item is the subject of a warning.
        var highlighted = false
        var id: String { label }
    }

    var facts: [Fact]
    var minimum: CGFloat = 240

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 8)], spacing: 8) {
            ForEach(facts) { fact in
                HStack(spacing: 10) {
                    Text(fact.label)
                        .foregroundStyle(.fgMuted)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let statement = fact.statement {
                        Text(statement)
                            .foregroundStyle(.fgMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(statement)
                    } else {
                        FactLabel(value: fact.value, yes: fact.yes, no: fact.no)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(fact.highlighted ? StatusTone.warn.soft : Color.surface1,
                            in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                .overlay {
                    if fact.highlighted {
                        RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                            .strokeBorder(StatusTone.warn.line, lineWidth: 1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
