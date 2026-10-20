import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Node…") { model.presentAddNode() }
                .keyboardShortcut("n")
        }

        // Finder's shortcut for the sidebar. Replaces the system item so there's exactly one.
        CommandGroup(replacing: .sidebar) {
            Button(model.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }

        CommandMenu("Node") {
            Button("All Nodes") { model.showAllNodes() }
                .keyboardShortcut("0")

            Divider()

            if model.nodes.isEmpty {
                Button("No Nodes") {}
                    .disabled(true)
            }
            ForEach(Array(model.nodes.prefix(9).enumerated()), id: \.element.id) { position, node in
                Button(node.displayName) { model.selectNode(atPosition: position) }
                    .keyboardShortcut(KeyEquivalent(Character(String(position + 1))))
            }

            Divider()

            Menu("Go To") {
                ForEach(NodeSection.allCases) { section in
                    Button(section.title) { model.select(section) }
                }
            }
            .disabled(model.selectedNodeID == nil)

            Button("Pair This Mac…") {
                if let id = model.selectedNodeID { model.presentPairing(for: id) }
            }
            .disabled(model.selectedNode.map { $0.pairing.isPaired } ?? true)
        }
    }
}
