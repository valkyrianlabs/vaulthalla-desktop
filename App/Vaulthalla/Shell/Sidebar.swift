import AppKit
import SwiftUI
import VHCore
import VHTransport

/// A sidebar row. Picking a node makes it the context for the section rows below; the highlight then sits on the
/// section, and the node row marks itself as current.
enum SidebarItem: Hashable {
    case allNodes
    /// Recovery Keys across every node.
    case allRecoveryKeys
    case node(NodeID)
    case section(NodeSection)
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            Label("All Nodes", systemImage: "square.grid.2x2")
                .tag(SidebarItem.allNodes)
            Label("Recovery Keys", systemImage: NodeSection.recoveryKeys.systemImage)
                .recoveryKeysBadge()
                .tag(SidebarItem.allRecoveryKeys)

            Section("Nodes") {
                if model.nodes.isEmpty && model.registryProblem == nil {
                    addNodeCallToAction
                }
                ForEach(model.nodes) { node in
                    NodeRow(node: node, status: model.status(for: node), isCurrent: isCurrent(node),
                            incompatibility: model.incompatibility(for: node))
                        .tag(SidebarItem.node(node.id))
                        .contextMenu { contextMenu(for: node) }
                }
                .onMove { model.moveNodes(fromOffsets: $0, toOffset: $1) }
            }

            if let node = model.selectedNode {
                Section(node.displayName) {
                    ForEach(NodeSection.allCases) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .syncConflictsBadge(section: section, node: node)
                            .recoveryKeysBadge(section: section, node: node)
                            .tag(SidebarItem.section(section))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let problem = model.registryProblem {
                RegistryProblemBanner(message: problem, fileURL: model.registryURL) { model.loadNodes() }
                    .padding(10)
            } else if !model.isCredentialOwner {
                ConsumerBanner(owner: model.credentialOwner)
                    .padding(10)
            }
        }
    }

    private var addNodeCallToAction: some View {
        Button {
            model.presentAddNode()
        } label: {
            Label("Add a Node…", systemImage: "plus.circle")
                .foregroundStyle(.accentText)
        }
        .buttonStyle(.plain)
        .selectionDisabled()
    }

    @ViewBuilder
    private func contextMenu(for node: Node) -> some View {
        Button("Rename…") { model.nodePendingRename = node }
        if !node.pairing.isPaired || model.needsPairingAgain(node.id) {
            Button(node.pairing.isPaired ? "Pair Again…" : "Pair This Mac…") { model.presentPairing(for: node.id) }
        }
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.endpoint.description, forType: .string)
        }
        Divider()
        Button("Remove…", role: .destructive) { model.nodePendingRemoval = node }
    }

    private func isCurrent(_ node: Node) -> Bool {
        model.selectedNodeID == node.id && !model.showsAllNodes
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if model.showsAllNodes { return model.allNodesPage == .recoveryKeys ? .allRecoveryKeys : .allNodes }
                return model.selectedNodeID == nil ? nil : .section(model.selectedSection)
            },
            set: { item in
                switch item {
                case .allNodes: model.showAllNodes()
                case .allRecoveryKeys: model.showAllRecoveryKeys()
                case .node(let id): model.selectNode(id)
                case .section(let section): model.select(section)
                case nil: break
                }
            }
        )
    }
}

struct NodeRow: View {
    var node: Node
    var status: NodeConnectionStatus
    var isCurrent = false
    /// Set when the node runs a Vaulthalla this build shares no protocol version with: a small badge says so.
    var incompatibility: ProtocolMismatch?

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: status.tone, pulse: status.isTransitional)
                .help(status.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.displayName)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Text(node.endpoint.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let incompatibility {
                IncompatibleBadge(mismatch: incompatibility)
            }
            if isCurrent {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.accentText)
                    .accessibilityLabel("Current node")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(incompatibility == nil ? status.label : "\(status.label), incompatible")
    }
}

/// The sidebar's mark for a node this build can't work with: which side to update, the full sentence on hover.
private struct IncompatibleBadge: View {
    var mismatch: ProtocolMismatch

    var body: some View {
        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            .font(.caption.weight(.semibold))
            .foregroundStyle(StatusTone.danger.color)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(StatusTone.danger.soft, in: Capsule())
            .overlay { Capsule().strokeBorder(StatusTone.danger.line, lineWidth: 1) }
            .help(mismatch.message)
            .accessibilityLabel(mismatch.side == .desktopTooOld ? "Needs a newer Vaulthalla Desktop"
                : "Needs a newer Vaulthalla on the node")
    }
}

/// This app is a credential consumer: another process holds the lease (docs/architecture.md §3).
private struct ConsumerBanner: View {
    var owner: CredentialLease.Holder?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Read-only", systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(StatusTone.info.color)
            Text(ownerText + " manages this Mac's keys and saved nodes. This window shows them and takes over when it quits.")
                .font(.caption)
                .foregroundStyle(.fgMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(StatusTone.info.soft, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(StatusTone.info.line)
        }
    }

    private var ownerText: String {
        guard let owner else { return "Another Vaulthalla process" }
        return "Another Vaulthalla process (\(owner.name), pid \(owner.pid))"
    }
}

private struct RegistryProblemBanner: View {
    var message: String
    var fileURL: URL
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved nodes unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(StatusTone.warn.color)
            Text(message)
                .font(.caption)
                .foregroundStyle(.fgMuted)
            Text("Vaulthalla won't overwrite the file. Fix or move it, then try again.")
                .font(.caption)
                .foregroundStyle(.fgSubtle)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                Button("Try Again", action: retry)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(StatusTone.warn.soft, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(StatusTone.warn.line)
        }
    }
}

#if DEBUG
#Preview("Sidebar") {
    NavigationSplitView {
        Sidebar()
    } detail: {
        Color.canvas
    }
    .environment(PreviewSamples.model(selecting: PreviewSamples.nodes[0].id))
    .preferredColorScheme(.dark)
    .frame(width: 900, height: 640)
}
#endif
