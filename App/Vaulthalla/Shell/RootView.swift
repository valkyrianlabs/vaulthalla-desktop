import SwiftUI
import VHCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("shell.selection") private var storedSelection = RestorableSelection()
    @State private var restored = false
    @State private var renameText = ""
    @State private var activity: AppActivity?

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 980, minHeight: 640)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CostAlertsBell()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Node", systemImage: "plus") { model.presentAddNode() }
                    .help("Add a Vaulthalla node (⌘N)")
            }
        }
        .sheet(item: $model.sheet) { sheet in
            AddNodeSheet(start: sheet)
        }
        .alert("Couldn't save the change", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Rename Node", isPresented: renameBinding, presenting: model.nodePendingRename) { node in
            TextField("Name", text: $renameText)
            Button("Rename") { model.rename(node.id, to: renameText) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("Only this Mac sees the name. The node at \(node.endpoint.description) is unchanged.")
        }
        .onChange(of: model.nodePendingRename) { _, node in
            renameText = node?.displayName ?? ""
        }
        .confirmationDialog(
            "Remove \(model.nodePendingRemoval?.displayName ?? "this node")?",
            isPresented: removalBinding,
            presenting: model.nodePendingRemoval
        ) { node in
            Button("Remove", role: .destructive) { model.remove(node.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This Mac forgets the node. Nothing changes on the server, where a paired device stays listed until it's revoked.")
        }
        .onAppear {
            if activity == nil {
                activity = AppActivity { [model] active in model.setAppActive(active) }
            }
            guard !restored else { return }
            restored = true
            model.restorableSelection = storedSelection
            #if DEBUG
            DebugSnapshot.run(model: model)
            #endif
        }
        .onChange(of: model.restorableSelection) { _, selection in
            if restored { storedSelection = selection }
        }
        .preferredColorScheme(.dark)
        .tint(.accentFill)
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { model.nodePendingRename != nil }, set: { if !$0 { model.nodePendingRename = nil } })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { model.nodePendingRemoval != nil }, set: { if !$0 { model.nodePendingRemoval = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

#if DEBUG
#Preview("Shell · nodes") {
    RootView()
        .environment(PreviewSamples.model())
}

#Preview("Shell · empty") {
    RootView()
        .environment(PreviewSamples.model(nodes: []))
}
#endif
