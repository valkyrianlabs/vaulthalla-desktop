import AppKit
import SwiftUI

/// What a column sorts by. Missing values sort last in either direction, so "not reported" never tops a list.
nonisolated enum DataSortKey: Comparable, Sendable {
    case number(Double?)
    case text(String?)

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.number(let l?), .number(let r?)): l < r
        case (.text(let l?), .text(let r?)): l.localizedStandardCompare(r) == .orderedAscending
        default: false
        }
    }

    var isMissing: Bool {
        switch self {
        case .number(let value): value == nil
        case .text(let value): value == nil
        }
    }
}

/// The column a table is sorted by, and which way.
struct DataSort: Hashable, Sendable {
    var column: String
    var ascending: Bool
}

/// How wide a ``DataColumn`` is.
nonisolated enum DataColumnWidth: Sendable {
    /// Exactly this wide.
    case fixed(CGFloat)
    /// A share of what the fixed columns leave, never under `min`.
    case flexible(min: CGFloat, weight: CGFloat = 1)
}

/// One column of a ``DataTable``.
struct DataColumn<Row>: Identifiable {
    typealias Width = DataColumnWidth

    let id: String
    var title: String
    var width: Width
    var alignment: Alignment
    /// Hidden while the table is narrower than this: the less important columns go first on a small window.
    var hideBelow: CGFloat
    var help: String?
    var sortKey: ((Row) -> DataSortKey)?
    var cell: @MainActor (Row) -> AnyView

    init<Cell: View>(
        _ id: String,
        _ title: String,
        width: Width = .flexible(min: 80),
        alignment: Alignment = .leading,
        hideBelow: CGFloat = 0,
        help: String? = nil,
        sortKey: ((Row) -> DataSortKey)? = nil,
        @ViewBuilder cell: @escaping @MainActor (Row) -> Cell
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.alignment = alignment
        self.hideBelow = hideBelow
        self.help = help
        self.sortKey = sortKey
        self.cell = { AnyView(cell($0)) }
    }

    /// Numbers sort descending first (biggest on top); text ascending.
    var startsDescending: Bool { alignment == .trailing }
}

/// A sortable table that lives inside a scrolling page (a SwiftUI `Table` scrolls on its own and wants the whole
/// page): column headers sort, rows highlight on hover and select on click, ↑ ↓ move the selection, ⌘C copies the
/// selected row, and columns marked `hideBelow` give way on a narrow window. Meant for tens of rows, not thousands.
struct DataTable<Row, ID: Hashable>: View {
    var rows: [Row]
    var id: (Row) -> ID
    var columns: [DataColumn<Row>]
    @Binding var sort: DataSort?
    @Binding var selection: ID?
    /// A row's status: a colored edge on the row. Nil for an ordinary row.
    var tone: (Row) -> StatusTone? = { _ in nil }
    /// The hover text for a row: its full breakdown.
    var help: ((Row) -> String)?
    /// The row as text for ⌘C and "Copy".
    var copyText: ((Row) -> String)?
    /// Return (or a double click) on a row.
    var open: ((Row) -> Void)?
    var empty = "Nothing to show."

    @State private var hovered: ID?
    @FocusState private var focused: Bool

    private static var rowHeight: CGFloat { 28 }
    private static var cellPadding: CGFloat { 8 }

    var body: some View {
        let sorted = sortedRows
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.line).frame(height: 1)
            if sorted.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ForEach(Array(sorted.enumerated()), id: \.offset) { index, row in
                    rowView(row, index: index)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1, in: sorted) }
        .onKeyPress(.downArrow) { move(1, in: sorted) }
        .onKeyPress(.escape) {
            guard selection != nil else { return .ignored }
            selection = nil
            return .handled
        }
        .onKeyPress(.return) {
            guard let open, let row = selectedRow(in: sorted) else { return .ignored }
            open(row)
            return .handled
        }
        .onCopyCommand {
            guard let copyText, let row = selectedRow(in: sorted) else { return [] }
            return [NSItemProvider(object: copyText(row) as NSString)]
        }
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(focused ? Color.accentLine : Color.line, lineWidth: 1)
        }
    }

    // MARK: Header

    private var rowLayout: DataRowLayout {
        DataRowLayout(widths: columns.map(\.width), hideBelow: columns.map(\.hideBelow))
    }

    private var header: some View {
        rowLayout {
            ForEach(columns) { column in
                headerCell(column)
                    .frame(maxWidth: .infinity, alignment: column.alignment)
                    .clipped()
            }
        }
        .frame(height: Self.rowHeight)
        .padding(.leading, 3)
    }

    @ViewBuilder
    private func headerCell(_ column: DataColumn<Row>) -> some View {
        let active = sort?.column == column.id
        let label = HStack(spacing: 3) {
            Text(column.title.uppercased())
                .lineLimit(1)
            if active, let sort {
                Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .font(.caption2.weight(.medium))
        .tracking(0.5)
        .foregroundStyle(active ? Color.fg : Color.fgSubtle)
        .padding(.horizontal, Self.cellPadding)
        .frame(maxWidth: .infinity, alignment: column.alignment)

        if column.sortKey != nil {
            Button {
                if active, let current = sort {
                    sort = DataSort(column: column.id, ascending: !current.ascending)
                } else {
                    sort = DataSort(column: column.id, ascending: !column.startsDescending)
                }
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(column.help.map { "\($0) Click to sort." } ?? "Sort by \(column.title.lowercased())")
            .accessibilityLabel("\(column.title), \(active ? (sort?.ascending == true ? "sorted ascending" : "sorted descending") : "sortable")")
        } else {
            label.help(column.help ?? "")
        }
    }

    // MARK: Rows

    private func rowView(_ row: Row, index: Int) -> some View {
        let rowID = id(row)
        let isSelected = selection == rowID
        let rowTone = tone(row)
        return rowLayout {
            ForEach(columns) { column in
                column.cell(row)
                    .lineLimit(1)
                    .padding(.horizontal, Self.cellPadding)
                    .frame(maxWidth: .infinity, alignment: column.alignment)
                    .clipped()
            }
        }
        .font(.callout)
        .frame(height: Self.rowHeight)
        .padding(.leading, 3)
        .background {
            if isSelected {
                Rectangle().fill(focused ? Color.accentSoft : Color.surface2)
            } else if hovered == rowID {
                Rectangle().fill(Color.surface1)
            }
        }
        .overlay(alignment: .leading) {
            if let rowTone {
                Rectangle().fill(rowTone.color).frame(width: 3)
            }
        }
        .overlay(alignment: .top) {
            if index > 0 { Rectangle().fill(Color.line.opacity(0.6)).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = rowID } else if hovered == rowID { hovered = nil }
        }
        .onTapGesture(count: 2) {
            selection = rowID
            open?(row)
        }
        .onTapGesture {
            selection = rowID
            focused = true
        }
        .help(help?(row) ?? "")
        .contextMenu {
            if let copyText {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText(row), forType: .string)
                }
            }
            if let open {
                Button("Open") { open(row) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Sorting and selection

    private var sortedRows: [Row] {
        guard let sort, let column = columns.first(where: { $0.id == sort.column }), let key = column.sortKey else {
            return rows
        }
        return rows.enumerated().sorted { lhs, rhs in
            let (l, r) = (key(lhs.element), key(rhs.element))
            if l.isMissing != r.isMissing { return !l.isMissing }
            if l == r { return lhs.offset < rhs.offset }
            return sort.ascending ? l < r : r < l
        }.map(\.element)
    }

    private func selectedRow(in rows: [Row]) -> Row? {
        guard let selection else { return nil }
        return rows.first { id($0) == selection }
    }

    private func move(_ step: Int, in rows: [Row]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = selection.flatMap { selected in rows.firstIndex { id($0) == selected } }
        let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        selection = id(rows[next])
        return .handled
    }
}

extension DataTable where ID == String {
    /// A table without selection (rows still highlight on hover).
    init(rows: [Row], id: @escaping (Row) -> String, columns: [DataColumn<Row>], sort: Binding<DataSort?>,
         empty: String = "Nothing to show.") {
        self.init(rows: rows, id: id, columns: columns, sort: sort, selection: .constant(nil), empty: empty)
    }
}

/// Lays one table row's cells out for the width the row is offered: fixed columns take their width, flexible ones
/// share the rest by weight, and columns whose `hideBelow` the width doesn't reach get none (their cells clip away).
/// Header and rows use the same layout, so columns line up without measuring anything.
private struct DataRowLayout: Layout {
    var widths: [DataColumnWidth]
    var hideBelow: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumWidth
        let columns = columnWidths(width)
        let height = zip(subviews, columns).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, columnWidths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: .init(width: width, height: bounds.height))
            x += width
        }
    }

    private var minimumWidth: CGFloat {
        widths.reduce(0) { total, width in
            switch width {
            case .fixed(let value): total + value
            case .flexible(let min, _): total + min
            }
        }
    }

    private func columnWidths(_ available: CGFloat) -> [CGFloat] {
        let shown = hideBelow.map { available >= $0 }
        var fixed: CGFloat = 0
        var minimums: CGFloat = 0
        var weights: CGFloat = 0
        for (width, isShown) in zip(widths, shown) where isShown {
            switch width {
            case .fixed(let value): fixed += value
            case .flexible(let min, let weight):
                minimums += min
                weights += weight
            }
        }
        let spare = max(available - fixed - minimums, 0)
        return zip(widths, shown).map { width, isShown in
            guard isShown else { return 0 }
            return switch width {
            case .fixed(let value): value
            case .flexible(let min, let weight): min + (weights > 0 ? spare * weight / weights : 0)
            }
        }
    }
}
