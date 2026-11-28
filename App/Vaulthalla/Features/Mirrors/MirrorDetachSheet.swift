import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Leaves a mirror with its files (`mirror.detach.preview`, then `mirror.detach {vault_id, owner, confirm_name}`), as
/// the console's DetachDialog: what detaching gives first (the changes kept, the files whose contents never arrived,
/// with their list to copy), the owner here, then the vault's name typed. Detach stays off until the preview has
/// answered and the name matches.
struct MirrorDetachSheet: View {
    /// How many missing files the sheet lists; the copy button carries all of them.
    static let shownMissing = 50

    var row: MirroredVault
    var queries: NodeQueries

    @State private var owner = ""
    @State private var typed = ""
    @State private var detached = false
    @State private var detach: NodeMutation<Ws.Mirror.Detach>
    private let preview: NodeQuery<Ws.Mirror.Detach.Preview>

    init(row: MirroredVault, queries: NodeQueries) {
        self.row = row
        self.queries = queries
        preview = queries.query(Ws.Mirror.Detach.Preview.self, .init(vaultID: row.vaultID))
        _detach = State(initialValue: NodeMutation(Ws.Mirror.Detach.self, on: queries,
                                                   invalidating: MirrorActions.invalidating))
    }

    var body: some View {
        MirrorActionSheet(destructive: true, systemImage: "folder", title: MirrorCopy.detachTitle(row.vaultName),
                          description: detached ? nil : MirrorCopy.detachBody(MirrorModel.peerName(row)), width: 580) {
            if detached {
                MirrorOutcome(label: MirrorCopy.detached(row.vaultName), tone: .ok) {
                    Text(MirrorCopy.detachedHint).foregroundStyle(.fgMuted)
                }
            } else if let p = preview.value?.preview {
                form(p)
            } else if let error = preview.error {
                MirrorRefusal(title: MirrorCopy.detachFailed, error: error)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(MirrorCopy.detachLoading)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
        } buttons: {
            if detached {
                MirrorCloseButton(label: MirrorCopy.done)
            } else {
                MirrorCloseButton(disabled: detach.isRunning)
                MirrorActionButton(label: MirrorCopy.detachConfirm, destructive: true, running: detach.isRunning,
                                   enabled: preview.value != nil
                                       && MirrorActions.detachPayload(row, owner: owner, typed: typed) != nil) {
                    Task { await submit() }
                }
            }
        }
        // Fresh facts each time it opens: what detaching gives changes as the copy moves.
        .task { await preview.refresh() }
        .observing(preview)
        .serverConfirmation(detach, title: MirrorCopy.detachTitle(row.vaultName), confirmLabel: MirrorCopy.detachConfirm,
                            role: .destructive)
        .interactiveDismissDisabled(detach.isRunning)
        .mirrorDebugConfirm {
            typed = row.vaultName
            while preview.value == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            await submit()
        }
    }

    @ViewBuilder
    private func form(_ p: Ws.Mirror.Detach.Preview.Response.Preview) -> some View {
        MirrorBullets(lines: MirrorActions.detachLines(p))

        if p.missingCount > 0 {
            MirrorWarning(title: MirrorCopy.detachMissingTitle(p.missingCount)) {
                if !p.missing.isEmpty {
                    MirrorCopyListButton(label: MirrorCopy.detachCopyList,
                                         text: p.missing.map(\.path).joined(separator: "\n"))
                }
            } content: {
                Text(MirrorCopy.detachMissingBody)
                    .fixedSize(horizontal: false, vertical: true)
                if !p.missing.isEmpty {
                    MirrorPathList(
                        items: p.missing.prefix(Self.shownMissing).map {
                            .init(id: "\($0.fileID)", path: $0.path, detail: Format.bytes($0.sizeBytes))
                        },
                        more: p.missing.count > Self.shownMissing
                            ? MirrorCopy.detachMissingMore(p.missingCount - Int64(Self.shownMissing)) : nil)
                    .padding(.top, 4)
                }
            }
        } else {
            Text(MirrorCopy.detachAllHere)
                .font(.callout)
                .foregroundStyle(.fgMuted)
        }

        MirrorOwnerField(queries: queries, label: MirrorCopy.detachOwner, hint: MirrorCopy.detachOwnerHint,
                         owner: $owner)
        MirrorTypedName(label: MirrorCopy.detachType(row.vaultName), name: row.vaultName, text: $typed)
        MirrorRefusal(title: MirrorCopy.detachFailed, error: detach.error)
    }

    private func submit() async {
        guard preview.value != nil, let payload = MirrorActions.detachPayload(row, owner: owner, typed: typed) else {
            return
        }
        detached = await detach.run(payload) != nil
    }
}
