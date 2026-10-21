import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// One table for "your devices" and a super admin's "all devices" (`showsOwner`): this Mac marked, rename, revoke,
/// revoked devices behind a toggle (the web console's DeviceTable).
struct DeviceTable: View {
    var node: Node
    var queries: NodeQueries
    var devices: [WsModel.Device]
    var showsOwner: Bool

    @State private var selection: Int64?
    @State private var sortOrder = [KeyPathComparator(\DeviceRow.statusSort), KeyPathComparator(\DeviceRow.pairedSort)]
    @State private var showsRevoked = false
    @State private var filter = ""
    @State private var renaming: DeviceRow?
    @State private var revoking: WsModel.Device?
    @State private var unpairing = false
    @State private var revoke: NodeMutation<Ws.Device.Revoke>

    init(node: Node, queries: NodeQueries, devices: [WsModel.Device], showsOwner: Bool) {
        self.node = node
        self.queries = queries
        self.devices = devices
        self.showsOwner = showsOwner
        _revoke = State(initialValue: NodeMutation(Ws.Device.Revoke.self, on: queries, invalidating: ["device.list"]))
    }

    private var thisMac: String? { node.pairedDeviceID }

    var body: some View {
        let revokedCount = devices.filter(\.revoked).count
        let rows = rows()

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Filter devices", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if revokedCount > 0 {
                    Toggle("Show revoked (\(revokedCount))", isOn: $showsRevoked)
                        .toggleStyle(.checkbox)
                        .foregroundStyle(.fgMuted)
                }
                Spacer(minLength: 0)
                Text(rows.count == 1 ? "1 device" : "\(rows.count) devices")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            }
            .padding(.horizontal, Theme.pagePadding)

            if let error = revoke.error {
                MutationError(error: error)
                    .padding(.horizontal, Theme.pagePadding)
            }

            table(rows)
        }
        .sheet(item: $renaming) { row in
            RenameDeviceSheet(device: row.device, queries: queries)
        }
        .confirmationDialog(revoking.map { "Revoke “\(DeviceFormat.label($0.name))”?" } ?? "", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }
        ), titleVisibility: .visible, presenting: revoking) { device in
            Button("Revoke", role: .destructive) {
                Task { await revoke.run(.init(deviceID: device.deviceID)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("\(device.platform.localizedCaseInsensitiveContains("mac") ? "That Mac" : "That device") loses access immediately and must pair again.\(showsOwner ? " It belongs to \(device.userName)." : "") Its open connections close now and its key is never accepted again.")
        }
        .unpairThisMac(node: node, queries: queries, isPresented: $unpairing)
    }

    // MARK: Table

    private func table(_ rows: [DeviceRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.isThisMac ? "laptopcomputer" : "desktopcomputer")
                        .foregroundStyle(row.device.revoked ? Color.fgFaint : Color.accentText)
                        .frame(width: 18)
                    Text(DeviceFormat.label(row.device.name))
                        .foregroundStyle(row.device.revoked ? Color.fgSubtle : Color.fg)
                        .lineLimit(1)
                    if row.isThisMac {
                        DeviceTag(text: "This Mac", tone: .info)
                    }
                    if row.device.revoked {
                        DeviceTag(text: "Revoked", tone: .unknown)
                            .help(row.device.revokedAt.map { "Revoked \(DeviceFormat.moment(epoch: $0))" } ?? "Revoked")
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 220, ideal: 300)

            if showsOwner {
                TableColumn("Owner", value: \.device.userName) { row in
                    Text(row.device.userName)
                        .foregroundStyle(.fgMuted)
                }
                .width(min: 70, ideal: 110)
            }

            TableColumn("Platform", value: \.device.platform) { row in
                Text(row.device.platform.isEmpty ? "—" : row.device.platform)
                    .foregroundStyle(.fgMuted)
            }
            .width(min: 60, ideal: 80)

            TableColumn("App Version", value: \.device.appVersion) { row in
                Text(row.device.appVersion.isEmpty ? "—" : row.device.appVersion)
                    .foregroundStyle(.fgMuted)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Paired", value: \.pairedSort) { row in
                Text(Format.relative(epoch: row.device.createdAt))
                    .foregroundStyle(.fgSubtle)
                    .help(DeviceFormat.moment(epoch: row.device.createdAt))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Last Seen", value: \.seenSort) { row in
                Text(row.device.lastSeenAt.map { Format.relative(epoch: $0) } ?? "Never")
                    .foregroundStyle(.fgSubtle)
                    .help(row.device.lastSeenAt.map { DeviceFormat.moment(epoch: $0) } ?? "")
            }
            .width(min: 80, ideal: 100)

            TableColumn("Last IP", value: \.ipSort) { row in
                Text(row.device.lastIP ?? "—")
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgSubtle)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Device ID") { row in
                Text(DeviceFormat.shortID(row.device.deviceID))
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgSubtle)
                    .help(row.device.deviceID)
            }
            .width(min: 100, ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                menu(for: row)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }), !row.device.revoked {
                renaming = row
            }
        }
    }

    @ViewBuilder
    private func menu(for row: DeviceRow) -> some View {
        Button("Copy Device ID") { DeviceFormat.copy(row.device.deviceID) }
        if !row.device.revoked {
            Button("Rename…") { renaming = row }
            Divider()
            if row.isThisMac {
                Button("Unpair This Mac…", role: .destructive) { unpairing = true }
            } else {
                Button("Revoke…", role: .destructive) { revoking = row.device }
            }
        }
    }

    private func rows() -> [DeviceRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return devices
            .filter { showsRevoked || !$0.revoked }
            .map { DeviceRow(device: $0, isThisMac: $0.deviceID.lowercased() == thisMac?.lowercased()) }
            .filter { needle.isEmpty || $0.searchText(includingOwner: showsOwner).contains(needle) }
            .sorted(using: sortOrder)
    }
}

/// One row of the device table.
nonisolated struct DeviceRow: Identifiable {
    var device: WsModel.Device
    var isThisMac: Bool

    var id: Int64 { device.id }
    var sortName: String { device.name.lowercased() }
    /// Live devices first, revoked ones after.
    var statusSort: Int { device.revoked ? 1 : 0 }
    /// Newest pairing first when sorted ascending.
    var pairedSort: Int64 { -device.createdAt }
    var seenSort: Int64 { device.lastSeenAt ?? 0 }
    var ipSort: String { device.lastIP ?? "" }

    func searchText(includingOwner: Bool) -> String {
        [device.name, device.platform, device.appVersion, device.lastIP ?? "", device.deviceID,
         includingOwner ? device.userName : ""].joined(separator: " ").lowercased()
    }
}

/// A small capsule tag inside a row ("This Mac", "Revoked").
struct DeviceTag: View {
    var text: String
    var tone: StatusTone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(tone.soft, in: Capsule())
            .overlay { Capsule().strokeBorder(tone.line, lineWidth: 1) }
            .fixedSize()
    }
}

/// Rename a device (`device.rename`): 1–64 characters, as core's `normalizeDeviceName` takes them.
struct RenameDeviceSheet: View {
    var device: WsModel.Device

    private static let maxName = 64

    @State private var name: String
    @State private var rename: NodeMutation<Ws.Device.Rename>
    @Environment(\.dismiss) private var dismiss

    init(device: WsModel.Device, queries: NodeQueries) {
        self.device = device
        _name = State(initialValue: device.name)
        _rename = State(initialValue: NodeMutation(Ws.Device.Rename.self, on: queries, invalidating: ["device.list"]))
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { trimmed.count > Self.maxName }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                } header: {
                    Text("Rename “\(DeviceFormat.label(device.name))”")
                } footer: {
                    Text(tooLong ? "At most \(Self.maxName) characters." : "The name shows in this list, in `vh device list` and in audit lines.")
                        .foregroundStyle(tooLong ? StatusTone.danger.color : .fgSubtle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: rename.error)
                .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || tooLong || trimmed == device.name || rename.isRunning)
            }
            .padding(20)
        }
        .frame(width: 440)
        .serverConfirmation(rename, title: "Rename the device?", confirmLabel: "Rename")
    }

    private func save() async {
        if await rename.run(.init(deviceID: device.deviceID, name: trimmed)) != nil { dismiss() }
    }
}

extension Node {
    /// The device id this Mac is paired as, when it is paired.
    var pairedDeviceID: String? {
        if case .paired(_, let deviceID, _) = pairing { return deviceID }
        return nil
    }
}
