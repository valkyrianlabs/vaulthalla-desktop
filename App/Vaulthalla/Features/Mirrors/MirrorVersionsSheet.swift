import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The versions a mirror keeps of what its core replaces or deletes (`mirror.versions.set`), as the console's
/// VersionsDialog. Where the console has no read of the setting and starts off and blank, Desktop starts from what
/// `mirror.get` reports (its settings), so saving never turns versions off by surprise; when the node doesn't report
/// it, the form starts off and blank with the console's note. It stays open and shows what the answer says was set.
struct MirrorVersionsSheet: View {
    var row: MirroredVault

    @State private var enabled: Bool
    @State private var keepLast: String
    @State private var maxAge: String
    @State private var quota: String
    @State private var saved: Ws.Mirror.Versions.Set.Response.Versions?
    @State private var save: NodeMutation<Ws.Mirror.Versions.Set>

    init(row: MirroredVault, queries: NodeQueries) {
        self.row = row
        let current = row.settings?.versions
        let text = { (v: Int64?) in v.map(String.init) ?? "" }
        _enabled = State(initialValue: current?.enabled ?? false)
        _keepLast = State(initialValue: text(current?.keepLast))
        _maxAge = State(initialValue: text(current?.maxAgeDays))
        _quota = State(initialValue: text(current?.quotaBytes))
        _save = State(initialValue: NodeMutation(Ws.Mirror.Versions.Set.self, on: queries,
                                                 invalidating: MirrorActions.invalidating))
    }

    private var payload: Ws.Mirror.Versions.Set.Payload? {
        MirrorActions.versionsPayload(row, enabled: enabled, keepLast: keepLast, maxAge: maxAge, quota: quota)
    }

    var body: some View {
        MirrorActionSheet(systemImage: "clock.arrow.circlepath", title: MirrorCopy.versionsTitle,
                          description: MirrorCopy.versionsBody) {
            if row.settings?.versions == nil {
                Text(MirrorCopy.versionsUnknown)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
            Toggle(MirrorCopy.versionsKeep, isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .foregroundStyle(.fg)
            if enabled {
                limits
                Text(MirrorCopy.versionsLimitHint)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
            if let saved {
                MirrorOutcome(label: MirrorCopy.versionsSaved(saved.enabled), tone: .ok) {
                    Text(MirrorActions.versionsText(saved, bytes: Format.bytes)).foregroundStyle(.fgMuted)
                }
            }
            MirrorRefusal(title: MirrorCopy.versionsFailed, error: save.error)
        } buttons: {
            MirrorCloseButton(label: MirrorCopy.close, disabled: save.isRunning)
            MirrorActionButton(label: MirrorCopy.versionsSave, running: save.isRunning, enabled: payload != nil) {
                Task { await submit() }
            }
        }
        .serverConfirmation(save, title: MirrorCopy.versionsTitle, confirmLabel: MirrorCopy.versionsSave)
        .interactiveDismissDisabled(save.isRunning)
        .mirrorDebugConfirm { await submit() }
    }

    /// The three limits side by side: labels on one row (bottom-aligned, as one may wrap), fields on the next, each
    /// field's error under it.
    private var limits: some View {
        let fields: [(String, Binding<String>, String)] = [
            (MirrorCopy.versionsKeepLast, $keepLast, "10"),
            (MirrorCopy.versionsMaxAge, $maxAge, "30"),
            (MirrorCopy.versionsQuota, $quota, "0"),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow(alignment: .bottom) {
                ForEach(fields, id: \.0) { field in
                    Text(field.0)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GridRow {
                ForEach(fields, id: \.0) { field in
                    TextField("", text: field.1, prompt: Text(field.2))
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .accessibilityLabel(field.0)
                }
            }
            if fields.contains(where: { MirrorActions.Limit($0.1.wrappedValue).error != nil }) {
                GridRow(alignment: .top) {
                    ForEach(fields, id: \.0) { field in
                        Text(MirrorActions.Limit(field.1.wrappedValue).error ?? "")
                            .font(.caption)
                            .foregroundStyle(StatusTone.danger.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func submit() async {
        guard let payload else { return }
        saved = await save.run(payload)?.versions
    }
}
