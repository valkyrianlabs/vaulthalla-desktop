import SwiftUI
import VHContract
import VHCore
import VHNodes

/// THE place a mirrored vault's actions go (the console's detail "Actions" panel). It lists the actions
/// ``MirrorModel/actions(_:firstCopyFinished:)`` allows for this server's role and the vault's state, with the
/// console's labels and hints, in the console's order. Each opens its own sheet (one file each beside this one),
/// which says what the action does and asks what the console asks (a typed name, a ticked box, a choice) before
/// anything is sent: nothing here runs an action. `held` is not a button: it is the held-changes list.
///
/// The sheets are presented by ``MirrorActionPresenter`` on the detail, so a sheet's outcome stays on screen while the
/// detail refreshes underneath it (an ended mirror no longer has this bar).
struct MirrorActionsBar: View {
    var node: Node
    var queries: NodeQueries
    var row: MirroredVault
    /// What `mirror.detach.preview` says about a held copy; nil while unknown or for other roles.
    var heldCopy: MirrorHeldCopyFacts?

    @Environment(\.presentMirrorAction) private var present
    @State private var local: MirrorActionRequest?

    var body: some View {
        let actions = MirrorModel.actions(row).filter { $0 != .held }
        Panel(title: MirrorCopy.detailActions) {
            if actions.isEmpty {
                Text(MirrorCopy.noActions)
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(actions, id: \.self) { action in
                        actionRow(action, MirrorModel.actionText(action, row))
                    }
                }
            }
        }
        // Without a presenter above (a preview), the bar presents its own sheets.
        .sheet(item: $local) { MirrorActionSheetContent(request: $0, node: node, queries: queries) }
        #if DEBUG
        .task { openDebugAction(actions) }
        #endif
    }

    private func actionRow(_ action: MirrorAction, _ text: MirrorModel.ActionText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(role: text.danger ? .destructive : nil) {
                perform(action)
            } label: {
                Label(text.label, systemImage: text.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .disabled(!available(action))
            .help(unavailableReason(action) ?? "")
            Text(text.hint)
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
            if action == .copy, row.role.holdsCopy {
                MirrorCopyRunningLine(vaultID: row.vaultID, queries: queries)
            }
        }
    }

    /// The command each action sends first: a node whose command set lacks it offers the button disabled.
    private static func command(_ action: MirrorAction) -> WsCommand? {
        switch action {
        case .switch: .mirrorSwitch
        case .takeover: .mirrorTakeover
        case .resync: .mirrorResync
        case .detach: .mirrorDetach
        case .copy: .mirrorDetachCopy
        case .versions: .mirrorVersionsSet
        case .cancel: .mirrorCancel
        case .held: nil
        }
    }

    private func available(_ action: MirrorAction) -> Bool {
        unavailableReason(action) == nil
    }

    private func unavailableReason(_ action: MirrorAction) -> String? {
        if MirrorModel.needsLink(action, row) { return MirrorCopy.resyncNeedsLink }
        if let command = Self.command(action), queries.supports(command: command) == .no {
            return "\(node.displayName) doesn’t offer this. Update Vaulthalla on it first."
        }
        return nil
    }

    private func perform(_ action: MirrorAction) {
        guard action != .held, available(action) else { return }
        let request = MirrorActionRequest(action: action, row: row)
        if let present { present(request) } else { local = request }
    }

    #if DEBUG
    /// `-VHDebugMirrorAction <switch|takeover|resync|detach|copy|versions|cancel>` opens that action's sheet on the
    /// mirror `-VHDebugMirror` opens, when it applies there (DebugSnapshot). Only ever with PREVIEW DATA.
    private func openDebugAction(_ actions: [MirrorAction]) {
        guard UserDefaults.standard.bool(forKey: "VHDebugPreviewData"),
              let raw = UserDefaults.standard.string(forKey: "VHDebugMirrorAction"),
              let action = MirrorAction(rawValue: raw), actions.contains(action),
              !MirrorDebug.opened else { return }
        MirrorDebug.opened = true
        perform(action)
    }
    #endif
}

/// One opened action: what it is and the row as it stood when it was opened (the sheet keeps it while the detail
/// refreshes).
struct MirrorActionRequest: Identifiable {
    let id = UUID()
    var action: MirrorAction
    var row: MirroredVault
}

/// Opens a mirror action's sheet from the detail (``MirrorActionPresenter``). Equal by presenter, so the environment
/// doesn't change on every update.
struct PresentMirrorAction: Equatable, Sendable {
    let presenter = UUID()
    let open: @MainActor @Sendable (MirrorActionRequest) -> Void

    @MainActor func callAsFunction(_ request: MirrorActionRequest) { open(request) }

    static func == (a: Self, b: Self) -> Bool { a.presenter == b.presenter }
}

extension EnvironmentValues {
    /// nil outside a ``MirrorActionPresenter``.
    @Entry var presentMirrorAction: PresentMirrorAction?
}

/// Presents the mirror action sheets from the detail page, which stays while its vault is shown: a sheet's outcome
/// (an ended mirror, a removed copy) stays until the person closes it, whatever the detail shows underneath. Every
/// mirror read is fetched again when a sheet closes.
struct MirrorActionPresenter: ViewModifier {
    var node: Node
    var queries: NodeQueries

    @State private var request: MirrorActionRequest?
    @State private var present: PresentMirrorAction?

    func body(content: Content) -> some View {
        content
            .environment(\.presentMirrorAction, present)
            .task {
                let binding = $request
                if present == nil { present = PresentMirrorAction { binding.wrappedValue = $0 } }
            }
            .sheet(item: $request, onDismiss: refresh) {
                MirrorActionSheetContent(request: $0, node: node, queries: queries)
            }
    }

    private func refresh() {
        for prefix in MirrorActions.invalidating { queries.invalidate(prefix: prefix) }
    }
}

/// The sheet for one action.
struct MirrorActionSheetContent: View {
    var request: MirrorActionRequest
    var node: Node
    var queries: NodeQueries

    var body: some View {
        let row = request.row
        Group {
            switch request.action {
            case .switch: MirrorSwitchSheet(row: row, queries: queries)
            case .takeover: MirrorTakeoverSheet(row: row, queries: queries)
            case .resync: MirrorResyncSheet(row: row, queries: queries)
            case .detach: MirrorDetachSheet(row: row, queries: queries)
            case .copy: MirrorDetachCopySheet(row: row, node: node, queries: queries)
            case .versions: MirrorVersionsSheet(row: row, queries: queries)
            case .cancel:
                if MirrorModel.cancelKind(row) == .end {
                    MirrorEndSheet(row: row, queries: queries)
                } else {
                    MirrorRemoveCopySheet(row: row, queries: queries)
                }
            case .held: EmptyView()
            }
        }
        .environment(queries)
    }
}

/// Under "Detach a copy…": a copy still being written, with its progress, so it can be found again after its sheet
/// closed. Nothing shows when none runs.
private struct MirrorCopyRunningLine: View {
    var vaultID: Int64
    var queries: NodeQueries

    var body: some View {
        let job = queries.supports(command: .mirrorDetachCopyGet) == .no ? nil
            : queries.query(Ws.Mirror.Detach.Copy.Get.self, .init(vaultID: vaultID))
        let running = job?.value?.copy.flatMap(MirrorCopyJob.init).flatMap { $0.isRunning ? $0 : nil }
        Group {
            if let running {
                let progress = running.progress(bytes: Format.bytes)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(MirrorCopy.copyStarted(running.name)) · \(progress.text)")
                        .font(.caption)
                        .foregroundStyle(.fgMuted)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    MirrorProgressBar(ratio: progress.ratio, label: MirrorCopy.copyRunning)
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
        .task(id: running != nil) {
            await job?.observe(polling: running != nil ? MirrorDetachCopySheet.poll : MirrorPolling.list)
        }
    }
}

#if DEBUG
/// DEBUG hooks for the action sheets (DebugSnapshot), only ever with PREVIEW DATA.
@MainActor
enum MirrorDebug {
    static var opened = false

    /// `-VHDebugMirrorConfirm YES`: the sheet presses its own action button once, so a snapshot shows its outcome.
    /// Compiled into DEBUG builds only, and only with `-VHDebugPreviewData YES`: it never reaches a real node.
    static var autoConfirm: Bool {
        UserDefaults.standard.bool(forKey: "VHDebugPreviewData") && UserDefaults.standard.bool(forKey: "VHDebugMirrorConfirm")
    }
}
#endif

extension View {
    /// DEBUG, PREVIEW DATA only: runs `action` once shortly after the sheet appears (``MirrorDebug/autoConfirm``).
    func mirrorDebugConfirm(_ action: @escaping @MainActor () async -> Void) -> some View {
        #if DEBUG
        task {
            guard MirrorDebug.autoConfirm else { return }
            try? await Task.sleep(for: .milliseconds(700))
            await action()
        }
        #else
        self
        #endif
    }
}
