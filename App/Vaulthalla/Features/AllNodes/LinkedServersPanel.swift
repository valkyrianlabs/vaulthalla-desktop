import SwiftUI
import VHCore
import VHNodes

/// All Nodes' "Linked servers" panel: for each node that links servers, the servers it is linked with and how each
/// connection is doing, as the node reports it (`peer.list`), with Rename and Unlink; any link only one side records,
/// with Unlink; pairs of nodes that aren't linked, as a quiet suggestion that only opens the Link Servers sheet; and
/// which nodes need a newer Vaulthalla. Shown once a node has said whether it links servers.
struct LinkedServersPanel: View {
    /// Opens the Link Servers sheet with these picked.
    var link: (NodeID?, NodeID?) -> Void
    /// Opens Accept a Link Request on the node.
    var accept: (NodeID) -> Void

    @Environment(AppModel.self) private var model
    @State private var unlinking: (node: Node, row: LinkedServer)?
    @State private var renaming: (node: Node, row: LinkedServer)?
    @State private var newName = ""

    private var linked: LinkedServersModel { model.linkedServers }

    var body: some View {
        Panel(title: "Linked servers",
              subtitle: "A link is a handshake between exactly two servers: each records the other's key, and a super "
                + "admin on each side approves. Mirrored vaults travel over it; a third server gains nothing.") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(linked.oneSided) { half in
                    Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                        Text(half.description)
                        Button("Unlink on \(half.nodeName)") { Task { await linked.unlink(half) } }
                            .controlSize(.small)
                            .disabled(linked.working.contains(half.id))
                    }
                }
                ForEach(linked.suggestions) { suggestion in
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.fgFaint)
                        Text(suggestion.description)
                            .foregroundStyle(.fgMuted)
                        Spacer(minLength: 4)
                        Button("Link…") { link(suggestion.first, suggestion.second) }
                            .controlSize(.small)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                }
                if let problem = linked.problem {
                    Callout(tone: .danger, systemImage: "xmark.octagon") { Text(problem) }
                }
                ForEach(linked.linkableNodes) { node in
                    nodeSection(node)
                }
                ForEach(linked.olderNodes) { node in
                    Text(ServerLinking.Failure.olderServer(node.displayName).description)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(unlinking.map { "Unlink \($0.row.name) from \($0.node.displayName)?" } ?? "",
                            isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
                            titleVisibility: .visible, presenting: unlinking) { target in
            Button("Unlink", role: .destructive) {
                Task { await linked.unlink(target.row, on: target.node.id) }
            }
        } message: { target in
            Text("\(target.node.displayName) stops trusting \(target.row.name)'s key and closes the connection; \(target.row.name) is told and unlinks too. Linking them again needs a new link.")
        }
        .alert("Rename \(renaming?.row.name ?? "")", isPresented: Binding(get: { renaming != nil },
                                                                           set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let target = renaming {
                    let name = newName
                    Task { await linked.rename(target.row, on: target.node.id, to: name) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The name \(renaming?.node.displayName ?? "this server") shows for it. The other server keeps its own.")
        }
    }

    @ViewBuilder
    private func nodeSection(_ node: Node) -> some View {
        let availability = linked.availability[node.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(node.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.fgMuted)
                Spacer(minLength: 4)
                if case .on = availability {
                    Button("Accept a Link Request…") { accept(node.id) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    Button("Link…") { link(node.id, nil) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
            }
            switch availability {
            case .notPermitted(.notSuperAdmin(_, let why))?:
                Text("This Mac's account here isn't a super admin (\(why)), so links with \(node.displayName) are requested from the other server, and an admin of \(node.displayName) approves them here.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            case .notPermitted(let reason)?:
                Text(reason.description)
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            case .on(let rows)? where rows.isEmpty:
                Text("Not linked with any server.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            case .on(let rows)?:
                ForEach(rows) { row in
                    LinkedServerRow(row: row, known: linked.node(for: row), working: linked.isWorking(row, on: node.id),
                                    rename: {
                                        newName = row.name
                                        renaming = (node, row)
                                    },
                                    unlink: { unlinking = (node, row) })
                }
            default:
                EmptyView()
            }
        }
    }
}

/// One linked server: connected or not and since when, which side dialled, the round trip, its version.
private struct LinkedServerRow: View {
    var row: LinkedServer
    /// The node this Mac knows by that key, if any.
    var known: Node?
    var working: Bool
    var rename: () -> Void
    var unlink: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .fontWeight(.medium)
                        .foregroundStyle(.fg)
                    if let known, known.displayName != row.name {
                        Text(known.displayName)
                            .font(.caption)
                            .foregroundStyle(.fgFaint)
                    }
                }
                Text(health)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if working {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button("Rename…", action: rename)
                Button("Unlink…", role: .destructive, action: unlink)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(working)
            .help("Rename or unlink \(row.name)")
        }
        .font(.callout)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var tone: StatusTone {
        if row.health.protocolCompatible == false { return .warn }
        return row.health.connected ? .ok : .unknown
    }

    private var health: String {
        let h = row.health
        var parts: [String] = []
        if h.connected {
            parts.append(h.since.map { "Connected since \(Format.relative($0))" } ?? "Connected")
            switch h.dialedBy {
            case .thisServer?: parts.append("this server dialled")
            case .peer?: parts.append("\(row.name) dialled")
            default: break
            }
            if let rtt = h.roundTrip {
                parts.append("\(rtt.components.seconds * 1000 + rtt.components.attoseconds / 1_000_000_000_000_000) ms")
            }
        } else {
            parts.append(h.since.map { "Not connected since \(Format.relative($0))" } ?? "Not connected")
            if let error = h.lastError { parts.append(error) }
            if let next = h.nextAttemptAt { parts.append("retrying \(Format.relative(next))") }
        }
        if let version = h.peerVersion ?? Optional(row.productVersion), !version.isEmpty {
            parts.append("Vaulthalla \(version)")
        }
        if h.protocolCompatible == false { parts.append("speaks an older link protocol: update it") }
        parts.append(row.comparedBy == "desktop" ? "linked by Desktop" : "linked by a person")
        return parts.joined(separator: " · ")
    }
}
