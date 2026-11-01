import SwiftUI

/// Places its children side by side, sharing the width by `weights`, once every column can be at least
/// `minColumnWidth` wide; below that they stack. The web's `lg:grid-cols-[2fr_1fr]` that follows the window instead of
/// a breakpoint: a page uses the whole window from a small one to an ultrawide.
struct AdaptiveColumns: Layout {
    /// One weight per child; missing weights count as 1.
    var weights: [CGFloat] = []
    var minColumnWidth: CGFloat = 320
    var spacing: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? idealWidth(subviews)
        if let widths = columnWidths(width, count: subviews.count) {
            let height = zip(subviews, widths).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(subviews.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let widths = columnWidths(bounds.width, count: subviews.count) {
            var x = bounds.minX
            for (subview, width) in zip(subviews, widths) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: .init(width: width, height: nil))
                x += width + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(.init(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: .init(width: bounds.width, height: height))
                y += height + spacing
            }
        }
    }

    /// The column widths, or nil when the columns would be narrower than `minColumnWidth` and should stack.
    private func columnWidths(_ width: CGFloat, count: Int) -> [CGFloat]? {
        guard count > 1 else { return [width] }
        let weights = (0..<count).map { $0 < self.weights.count ? max(self.weights[$0], 0.01) : 1 }
        let total = weights.reduce(0, +)
        let usable = width - spacing * CGFloat(count - 1)
        let widths = weights.map { usable * $0 / total }
        return widths.allSatisfy { $0 >= minColumnWidth } ? widths : nil
    }

    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }
}

/// A small uppercase label over a part of a panel (the web's `SubHeading`).
struct SubHeading: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.medium))
            .tracking(0.6)
            .foregroundStyle(.fgSubtle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Equal columns, as many as fit at `minimum` but never more than there are items, so two cards share a wide row
/// instead of leaving half of it empty. Rows align to the top; each is as tall as its tallest item.
struct FillingGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minimum * CGFloat(subviews.count)
        let rows = rowHeights(width, subviews)
        return CGSize(width: width, height: rows.heights.reduce(0, +) + spacing * CGFloat(max(rows.heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rowHeights(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in rows.heights.enumerated() {
            for column in 0..<rows.columns {
                let index = row * rows.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (rows.width + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .init(width: rows.width, height: nil))
            }
            y += height + spacing
        }
    }

    private func rowHeights(_ width: CGFloat, _ subviews: Subviews) -> (columns: Int, width: CGFloat, heights: [CGFloat]) {
        let fit = Int((width + spacing) / (minimum + spacing))
        let columns = max(1, min(subviews.count, fit))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(.init(width: columnWidth, height: nil)).height }
                .max() ?? 0
        }
        return (columns, columnWidth, heights)
    }
}

/// Panels flowing into as many columns as fit at `minimum`, each placed in the column that is shortest so far: a
/// dashboard of uneven panels without the gaps a grid leaves. One column below `2 × minimum`, in order.
struct MasonryColumns: Layout {
    var minimum: CGFloat
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        let placement = place(width, subviews)
        return CGSize(width: width, height: placement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = place(bounds.width, subviews)
        for (subview, frame) in zip(subviews, placement.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: .init(width: frame.width, height: nil))
        }
    }

    private func place(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let columns = max(1, min(subviews.count, Int((width + spacing) / (minimum + spacing))))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var tops = Array(repeating: CGFloat(0), count: columns)
        var frames: [CGRect] = []
        for subview in subviews {
            let column = tops.indices.min { tops[$0] < tops[$1] } ?? 0
            let height = subview.sizeThatFits(.init(width: columnWidth, height: nil)).height
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: tops[column], width: columnWidth,
                                 height: height))
            tops[column] += height + spacing
        }
        return (frames, max((tops.max() ?? 0) - spacing, 0))
    }
}
