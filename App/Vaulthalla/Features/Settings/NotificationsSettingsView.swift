import AppKit
import SwiftUI
import VHCore
import VHNodes

/// Settings ▸ Notifications (docs/mac-experience.md §6): the master switch, macOS's permission, one switch per kind
/// of notification, and nodes that are muted.
struct NotificationsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var fleet = model.fleet
        let hub = NotificationHub.shared
        Form {
            Section {
                Toggle(isOn: $fleet.settings.enabled) {
                    Text("Notify me about my nodes")
                    Text("Vaulthalla watches every paired node from the menu bar and tells you when one needs you. "
                         + "A problem is announced once, not repeatedly.")
                }
                permissionRow(hub)
            }

            Section("Tell me when") {
                ForEach(FleetNotice.allCases, id: \.self) { notice in
                    Toggle(isOn: Binding(get: { fleet.settings.isOn(notice) },
                                         set: { fleet.settings.set(notice, on: $0) })) {
                        Text(notice.title)
                        if let note = Self.note(notice) { Text(note) }
                    }
                }
            }
            .disabled(!fleet.settings.enabled)

            Section("Nodes") {
                if model.nodes.isEmpty {
                    Text("No nodes yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.nodes) { node in
                    Toggle(isOn: Binding(get: { !model.preferences.isMuted(node.id) },
                                         set: { model.preferences.setMuted(!$0, for: node.id) })) {
                        Text(node.displayName)
                        Text(model.preferences.isMuted(node.id)
                             ? "Muted: no notifications, and it stays out of the menu bar icon's state."
                             : node.endpoint.host)
                    }
                }
            }
            .disabled(!fleet.settings.enabled)
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
        .task { await hub.refreshPermission() }
        .onChange(of: scenePhase) { _, _ in Task { await hub.refreshPermission() } }
    }

    @ViewBuilder
    private func permissionRow(_ hub: NotificationHub) -> some View {
        switch hub.permission {
        case .allowed:
            LabeledContent("macOS", value: "Allowed")
        case .notAsked:
            LabeledContent {
                Button("Allow Notifications…") { Task { await hub.requestPermission() } }
            } label: {
                Text("macOS")
                Text("macOS asks once whether Vaulthalla may notify you.")
            }
        case .denied:
            LabeledContent {
                Button("Open System Settings…") { Self.openNotificationSettings() }
            } label: {
                Text("macOS")
                Text("Notifications are turned off for Vaulthalla in System Settings, so none of these arrive.")
                    .foregroundStyle(StatusTone.warn.color)
            }
        case .unknown:
            LabeledContent("macOS", value: "Not available")
        }
    }

    private static func note(_ notice: FleetNotice) -> String? {
        switch notice {
        case .nodeUnreachable: "After two minutes, and never while this Mac itself is offline."
        case .healthNotableWarning: "Nodes on Vaulthalla 1.28 or later say which warnings are worth a notification."
        case .healthWarning: "For older nodes, which don't say: off by default, since they raise one during every upload."
        case .healthError, .nodeReachable, .nodeRevoked, .nodeIncompatible, .healthCleared, .syncConflicts: nil
        }
    }

    private static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

#if DEBUG
#Preview("Settings · Notifications") {
    NotificationsSettingsView()
        .environment(PreviewSamples.liveModel())
        .frame(width: 520)
}
#endif
