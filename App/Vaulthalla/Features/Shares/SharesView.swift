import AppKit
import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// The node's share links (`share.link.list`): the caller's own across vaults, or every link of one vault the caller
/// may manage, in a sortable table with an inspector. Links are created, edited, rotated and revoked here; the full
/// address is shown once, when a link is created or rotated, because the daemon never returns its token again.
struct SharesView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            SharesScreen(node: node, queries: queries)
                .environment(queries)
        } else {
            PlaceholderSection(node: node, section: .shares)
        }
    }
}

/// Which links the table shows: `share.link.list` without a vault answers the caller's own links in every vault;
/// with one, all of that vault's links (needs the vault's share-management permission).
enum ShareScope: Hashable {
    case mine
    case vault(Int64)

    var vaultID: Int64? {
        if case .vault(let id) = self { return id }
        return nil
    }
}

private struct SharesScreen: View {
    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @State private var scope = ShareScope.mine
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\ShareRow.sortCreated, order: .reverse)]
    @State private var filter = ""
    @State private var showsInspector = true
    @State private var creating = false
    @State private var editing: ShareRow?
    @State private var rotating: ShareRow?
    @State private var revoking: ShareRow?
    /// Addresses issued while this screen was open (create, rotate), by link id: the only time they're known.
    @State private var issued: [String: IssuedLink] = [:]
    /// The address just issued, shown above the table until dismissed.
    @State private var fresh: (shareID: String, title: String, link: IssuedLink)?
    @State private var rotate: NodeMutation<Ws.Share.Link.RotateToken>
    @State private var revoke: NodeMutation<Ws.Share.Link.Revoke>

    init(node: Node, queries: NodeQueries) {
        self.node = node
        self.queries = queries
        _rotate = State(initialValue: NodeMutation(Ws.Share.Link.RotateToken.self, on: queries, invalidating: ["share.link"]))
        _revoke = State(initialValue: NodeMutation(Ws.Share.Link.Revoke.self, on: queries, invalidating: ["share.link"]))
    }

    var body: some View {
        let list = queries.query(Ws.Share.Link.List.self, Self.payload(scope))
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        let users = queries.query(Ws.Auth.Users.List.self)
        let policyQuery = queries.query(Ws.Settings.Policy.Get.self)
        let policy = SharingPolicy(policyQuery.value?.policy.sharing)
        let rows = rows(list: list, vaults: vaults, users: users)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: "Shares", subtitle: NodeSection.shares.summary) {
                let status = model.status(for: node)
                StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 10) {
                if let notice = policy.notice {
                    HeaderBanner(tone: .warn, systemImage: "link.badge.plus", text: notice)
                }
                if let fresh {
                    IssuedLinkPanel(title: fresh.title, link: fresh.link, node: node) { self.fresh = nil }
                }
                if let error = rotate.error ?? revoke.error {
                    HeaderBanner(error: error)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, policy.notice != nil || fresh != nil || (rotate.error ?? revoke.error) != nil ? 12 : 0)

            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "share links")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: subject) {
                    Task { await list.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, let at):
                StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
                if value.shares.isEmpty {
                    Panel {
                        EmptyState(emptyTitle, systemImage: "link", message: emptyMessage) {
                            if policy.enabled {
                                Button("New Share Link…") { creating = true }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    table(rows)
                }
            }
        }
        .observing(list)
        .observing(vaults)
        .observing(users)
        .observing(policyQuery)
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter Links")
        .inspector(isPresented: Binding(get: { showsInspector && !rows.isEmpty }, set: { showsInspector = $0 })) {
            inspector(rows: rows)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar { toolbar(vaults: vaults.value?.vaults ?? [], policy: policy) }
        .sheet(isPresented: $creating) {
            CreateShareSheet(node: node, queries: queries, policy: policy, initialVault: scope.vaultID) { share, link in
                issued[share.id] = link
                fresh = (share.id, ShareRow.title(of: share), link)
                selection = share.id
            }
        }
        .sheet(item: $editing) { row in
            EditShareSheet(row: row, queries: queries, policy: policy)
        }
        .confirmationDialog("Rotate this link?", isPresented: present($rotating), titleVisibility: .visible,
                            presenting: rotating) { row in
            Button("Rotate Link") { Task { await rotateLink(row) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Anyone using the current link loses access immediately, and its open sessions end. You'll get a new link to send.")
        }
        .confirmationDialog("Revoke this link?", isPresented: present($revoking), titleVisibility: .visible,
                            presenting: revoking) { row in
            Button("Revoke", role: .destructive) { Task { await revokeLink(row) } }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("“\(row.title)” stops working for everyone, permanently. Its sessions end on their next request.")
        }
        .serverConfirmation(rotate, title: "Rotate the link?", confirmLabel: "Rotate")
        .serverConfirmation(revoke, title: "Revoke the link?", confirmLabel: "Revoke", role: .destructive)
        .onChange(of: scope) { selection = nil }
        #if DEBUG
        .task { await debugHooks() }
        #endif
    }

    private var subject: String {
        scope == .mine ? "your share links" : "this vault's share links"
    }

    private var emptyTitle: String {
        scope == .mine ? "You haven't created any share links on \(node.displayName)" : "No share links in this vault"
    }

    private var emptyMessage: String {
        scope == .mine
            ? "Links you create appear here. Pick a vault in the toolbar to see every link in it, when your role may manage its shares."
            : "Links anyone created in this vault appear here."
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(vaults: [WsModel.Vault], policy: SharingPolicy) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Show", selection: $scope) {
                Text("Links I Created").tag(ShareScope.mine)
                if !vaults.isEmpty {
                    Divider()
                    ForEach(vaults.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.id) { vault in
                        Text(vault.name).tag(ShareScope.vault(vault.id))
                    }
                }
            }
            .pickerStyle(.menu)
            .help("Your own links in every vault, or all links of one vault")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New Share Link…", systemImage: "plus") { creating = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(policy.loaded && policy.modes.isEmpty)
                .help(policy.loaded && policy.modes.isEmpty ? "Sharing is turned off on this node" : "Share a file or folder (⌥⌘N)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    // MARK: Table

    private func table(_ rows: [ShareRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Link", value: \.sortTitle) { row in
                HStack(spacing: 10) {
                    ShareGlyph(isDirectory: row.isDirectory, state: row.state)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .foregroundStyle(row.state == .revoked ? Color.fgSubtle : Color.fg)
                        Text(row.share.rootPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.fgSubtle)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                }
                .padding(.vertical, 3)
            }
            .width(min: 180, ideal: 250)

            TableColumn("Vault", value: \.sortVault) { row in
                Text(row.vaultName)
                    .foregroundStyle(.fgMuted)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Kind", value: \.sortKind) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.kindTitle)
                        .foregroundStyle(.fgMuted)
                    Text(row.isEmailValidated ? "Verified email · \(row.operations)" : row.operations)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
                .lineLimit(1)
                .help("\(row.accessTitle). Allows \(row.operations).")
            }
            .width(min: 110, ideal: 160)

            TableColumn("State", value: \.sortState) { row in
                HStack(spacing: 6) {
                    StatusDot(tone: row.state.tone, size: 7)
                    Text(row.state.label)
                        .foregroundStyle(.fgMuted)
                }
            }
            .width(min: 70, ideal: 84)

            TableColumn("Expires", value: \.sortExpires) { row in
                Text(ShareDate.short(row.share.expiresAt) ?? "Never")
                    .foregroundStyle(row.share.expiresAt == nil ? Color.fgFaint : Color.fgMuted)
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn("Downloads", value: \.sortDownloads) { row in
                Text(row.downloads)
                    .foregroundStyle(row.downloadsAtLimit ? StatusTone.warn.color : Color.fgMuted)
                    .monospacedDigit()
                    .help(row.downloadsAtLimit ? "The download limit is reached: further downloads are refused." : "")
            }
            .width(min: 70, ideal: 86)

            TableColumn("Last Access", value: \.sortLastAccess) { row in
                Text(Format.date(iso: row.share.lastAccessedAt).map { Format.relative($0) } ?? "Never")
                    .foregroundStyle(row.share.lastAccessedAt == nil ? Color.fgFaint : Color.fgMuted)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Created", value: \.sortCreated) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(ShareDate.short(row.share.createdAt) ?? row.share.createdAt)
                        .foregroundStyle(.fgMuted)
                        .monospacedDigit()
                    Text(row.creatorName)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
                .lineLimit(1)
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                rowMenu(row)
            }
        } primaryAction: { ids in
            selection = ids.first
            showsInspector = true
        }
        .onDeleteCommand {
            if let selection, let row = rows.first(where: { $0.id == selection }), row.state != .revoked {
                revoking = row
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: ShareRow) -> some View {
        Button("Copy Link") { copy(issued[row.id]) }
            .disabled(issued[row.id] == nil)
        Button("Copy Path") { ShareClipboard.copy(row.share.rootPath) }
        if row.state != .revoked {
            Divider()
            Button("Edit…") { editing = row }
            Button("Rotate Link…") { rotating = row }
            Divider()
            Button("Revoke…", role: .destructive) { revoking = row }
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(rows: [ShareRow]) -> some View {
        if let selection, let row = rows.first(where: { $0.id == selection }) {
            ShareInspector(
                row: row, link: issued[row.id], updaterName: { userName($0) },
                onCopy: { copy(issued[row.id]) }, onEdit: { editing = row },
                onRotate: { rotating = row }, onRevoke: { revoking = row })
                .id(row.id)
        } else {
            EmptyState("No link selected", systemImage: "sidebar.trailing",
                       message: "Select a link to see what it shares, its limits and how it has been used.")
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func rotateLink(_ row: ShareRow) async {
        revoke.reset()
        guard let response = await rotate.run(.init(id: row.id)) else { return }
        let link = IssuedLink(path: response.publicURLPath, origin: await queries.shareLinkOrigin())
        issued[row.id] = link
        fresh = (row.id, ShareRow.title(of: response.share), link)
    }

    private func revokeLink(_ row: ShareRow) async {
        rotate.reset()
        guard await revoke.run(.init(id: row.id)) != nil else { return }
        issued[row.id] = nil
        if fresh?.shareID == row.id { fresh = nil }
    }

    private func copy(_ link: IssuedLink?) {
        guard let link else { return }
        ShareClipboard.copy(link.text)
    }

    private func present(_ item: Binding<ShareRow?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    // MARK: Rows

    private static func payload(_ scope: ShareScope) -> Ws.Share.Link.List.Payload {
        .init(vaultID: scope.vaultID.map { .value($0) }, limit: .value(500))
    }

    private func userName(_ id: Int64) -> String {
        let users = queries.query(Ws.Auth.Users.List.self).value?.users ?? []
        return users.first { $0.id == id }?.name ?? "User #\(id)"
    }

    private func rows(list: NodeQuery<Ws.Share.Link.List>, vaults: NodeQuery<Ws.Storage.Vault.List>,
                      users: NodeQuery<Ws.Auth.Users.List>) -> [ShareRow] {
        let vaultNames = Dictionary((vaults.value?.vaults ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let userNames = Dictionary((users.value?.users ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let now = Date.now
        return (list.value?.shares ?? [])
            .map { share in
                ShareRow(share: share, vaultName: vaultNames[share.vaultID] ?? "Vault #\(share.vaultID)",
                         creatorName: userNames[share.createdBy] ?? "User #\(share.createdBy)",
                         state: ShareState(share, now: now))
            }
            .filter { needle.isEmpty || $0.searchText.contains(needle) }
            .sorted(using: sortOrder)
    }

    #if DEBUG
    /// `-VHDebugShare <id>` selects a link; `-VHDebugShareSheet create|edit|issued` opens a sheet or shows the
    /// one-time link panel for it (DebugSnapshot).
    private func debugHooks() async {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "VHDebugShare") { selection = id }
        switch defaults.string(forKey: "VHDebugShareSheet") {
        case "create":
            creating = true
        case "edit", "issued":
            let list = queries.query(Ws.Share.Link.List.self, Self.payload(scope))
            while list.value == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            guard let share = list.value?.shares.first(where: { $0.id == selection }) ?? list.value?.shares.first
            else { return }
            let row = ShareRow(share: share, vaultName: "", creatorName: "", state: ShareState(share))
            if defaults.string(forKey: "VHDebugShareSheet") == "edit" {
                editing = row
            } else {
                let link = IssuedLink(path: "/share/preview-token-not-real", origin: await queries.shareLinkOrigin())
                issued[share.id] = link
                fresh = (share.id, row.title, link)
            }
        default:
            break
        }
    }
    #endif
}

extension ShareRow {
    static func title(of share: WsModel.ShareLink) -> String {
        ShareRow(share: share, vaultName: "", creatorName: "", state: .active).title
    }
}

extension NodeQueries {
    /// The web console's origin for share addresses: `email.base_url`, which the daemon puts in front of the links it
    /// emails. Only super admins may read the settings (`settings.get`); for anyone else it's nil and Desktop shows
    /// the path the daemon returned.
    func shareLinkOrigin() async -> String? {
        let settings = query(Ws.Settings.Get.self)
        await settings.refreshIfStale()
        return settings.value?.settings.email.baseURL
    }
}

/// "Oct 24", with the year only when it isn't this year: table cells stay narrow.
enum ShareDate {
    static func short(_ iso: String?) -> String? {
        guard let date = Format.date(iso: iso) else { return iso }
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}

enum ShareClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The address the daemon just issued: shown once, to copy now.
struct IssuedLinkPanel: View {
    var title: String
    var link: IssuedLink
    var node: Node
    var onDismiss: (() -> Void)?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.accentText)
                Text("“\(title)” is ready. Copy the link now")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Text(link.text)
                    .font(.callout.monospaced())
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(link.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(.line)
                    }
                Button {
                    ShareClipboard.copy(link.text)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }
            // No `fixedSize` here: wrapping text that sizes itself above the table loops AppKit's constraint pass.
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.fgSubtle)
        }
        .padding(12)
        .background(.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(.accentLine)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }

    private var footnote: String {
        let once = "For security, the full link is only shown once. Rotate it later to get a new one."
        guard link.url == nil else { return once }
        return "\(once) This is the link's path: put the address of \(node.displayName)'s web console in front of it (Desktop learns that address only from the node's email settings, which only super admins can read)."
    }
}

/// A one-line-or-more notice above a table. Unlike `Callout` it doesn't fix its own height: on a page that doesn't
/// scroll, self-sizing wrapped text above a `Table` sends AppKit's constraint pass into a loop that traps.
struct HeaderBanner: View {
    var tone: StatusTone
    var systemImage: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
            Text(text)
                .font(.callout)
                .foregroundStyle(.fg)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(tone.soft, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(tone.line, lineWidth: 1)
        }
    }
}

extension HeaderBanner {
    /// A mutation's failure, worded like `MutationError`.
    init(error: WsError) {
        switch QueryProblem(error) {
        case .noAnswerYet:
            self.init(tone: .info, systemImage: "hourglass",
                      text: "No answer yet. The node may still be working on it; check before trying again.")
        case .offline:
            self.init(tone: .info, systemImage: "bolt.horizontal.circle", text: "Not connected to the node. Nothing was changed.")
        case .denied(let message):
            self.init(tone: .warn, systemImage: "lock", text: "Not allowed: \(message)")
        default:
            self.init(tone: .danger, systemImage: "exclamationmark.circle", text: error.message)
        }
    }
}

/// A file or folder glyph, dimmed for a link that no longer works.
struct ShareGlyph: View {
    var isDirectory: Bool
    var state: ShareState
    var size: CGFloat = 26

    var body: some View {
        let live = state == .active
        Image(systemName: isDirectory ? "folder" : "doc")
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(live ? Color.accentText : Color.fgSubtle)
            .frame(width: size, height: size)
            .background(live ? Color.accentSoft : Color.surface2,
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(live ? Color.accentLine : Color.line, lineWidth: 1)
            }
    }
}

#if DEBUG
#Preview("Shares (preview data)") {
    let model = PreviewSamples.liveModel()
    SharesView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1200, height: 640)
}

#Preview("No links (preview data)") {
    let model = PreviewSamples.liveModel()
    SharesView(node: PreviewSamples.nodes[3])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 520)
}
#endif
