import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// This Mac's pairing with the node: its device id, where its key lives, since when it is paired, the server key it
/// pins; rotating the key now and unpairing.
struct ThisMacPanel: View {
    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @State private var unpairing = false
    /// The device id a rotation was requested from; cleared once the node took the new key.
    @State private var rotatingFrom: String?
    @State private var rotated = false

    private static let termWidth: CGFloat = 120

    var body: some View {
        Panel(title: "This Mac", subtitle: "How this Mac is paired with \(node.displayName).") {
            VStack(alignment: .leading, spacing: 14) {
                if case .paired(let pin, let deviceID, let since) = node.pairing {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 32, verticalSpacing: 10) {
                        GridRow {
                            fact("Device ID", value: DeviceFormat.abbreviated(deviceID),
                                 monospaced: true, copy: deviceID, help: deviceID)
                            fact("Key", value: backend)
                        }
                        GridRow {
                            fact("Server key", value: DeviceFormat.abbreviated(DeviceFormat.hex(pin)),
                                 monospaced: true, copy: DeviceFormat.hex(pin), help: DeviceFormat.hex(pin))
                            fact("Paired", value: since.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let next = node.nextServerSPKISHA256 {
                            GridRow {
                                fact("Next server key", value: DeviceFormat.abbreviated(DeviceFormat.hex(next)),
                                     monospaced: true, copy: DeviceFormat.hex(next), help: "\(node.displayName) announced it will switch to this key.")
                                    .gridCellColumns(2)
                            }
                        }
                    }
                    .font(.callout)
                }

                if rotated {
                    Label("The node took the new key. This Mac now connects with it.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(StatusTone.ok.color)
                }

                HStack(spacing: 10) {
                    Button {
                        rotate()
                    } label: {
                        if rotatingFrom != nil {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Rotating…")
                            }
                        } else {
                            Label("Rotate Key Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(rotatingFrom != nil || model.sessions?.session(for: node.id) == nil
                              || !model.isCredentialOwner)
                    .help(model.isCredentialOwner
                          ? "Make a new key for this Mac, signed by the current one. The node switches to it on the next connection; nothing else changes."
                          : "Another Vaulthalla process manages this Mac's keys and rotates them.")

                    Button("Unpair This Mac…", systemImage: "minus.circle", role: .destructive) { unpairing = true }
                        .disabled(!model.isCredentialOwner)
                        .help("Revoke this Mac on \(node.displayName) and delete its key here")
                    Spacer(minLength: 0)
                    Text("The key is rotated every 90 days on its own.")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
                .controlSize(.small)
            }
        }
        .onChange(of: node.pairedDeviceID) { _, new in
            // The rotation completed: the session recorded the new device id. The node's list shows it under it.
            guard let from = rotatingFrom, new != from, new != nil else { return }
            rotatingFrom = nil
            rotated = true
            queries.invalidate(prefix: "device.list")
        }
        .unpairThisMac(node: node, queries: queries, isPresented: $unpairing)
    }

    private var backend: String {
        model.keyBackends[node.id]?.displayName ?? "Not reported yet"
    }

    private func fact(_ term: String, value: String, monospaced: Bool = false, copy: String? = nil,
                      help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(term)
                .font(.caption)
                .foregroundStyle(.fgSubtle)
            HStack(spacing: 6) {
                Text(value)
                    .foregroundStyle(.fg)
                    .fontDesign(monospaced ? .monospaced : .default)
                    .lineLimit(1)
                    .help(help ?? value)
                if let copy {
                    Button("Copy \(term)", systemImage: "doc.on.doc") { DeviceFormat.copy(copy) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Copy the full \(term.lowercased())")
                }
            }
        }
    }

    private func rotate() {
        guard let deviceID = node.pairedDeviceID, let session = model.sessions?.session(for: node.id) else { return }
        rotated = false
        rotatingFrom = deviceID
        Task {
            do {
                try await session.rotateDeviceKey()
            } catch {
                rotatingFrom = nil
            }
        }
    }
}

// MARK: - Unpair

extension View {
    /// "Unpair this Mac": asks, revokes this Mac's device on the node, then deletes its key here and returns the node
    /// to unpaired, so it can be paired again with a fresh key (pairing.md §6).
    func unpairThisMac(node: Node, queries: NodeQueries, isPresented: Binding<Bool>) -> some View {
        modifier(UnpairThisMac(node: node, queries: queries, isPresented: isPresented))
    }
}

private struct UnpairThisMac: ViewModifier {
    var node: Node
    var queries: NodeQueries
    @Binding var isPresented: Bool

    @Environment(AppModel.self) private var model
    @State private var failure: WsError?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Unpair this Mac from \(node.displayName)?", isPresented: $isPresented,
                                titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { Task { await unpair() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This Mac loses access to \(node.displayName) now and its key is deleted here. The node never accepts that key again; to manage it from this Mac, pair again.")
            }
            .alert("This Mac wasn't unpaired", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                   presenting: failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.message)
            }
    }

    private func unpair() async {
        // Read before the first suspension: the section's views go away once the node is unpaired.
        let model = self.model
        let id = node.id
        guard let deviceID = node.pairedDeviceID else { return }
        // Revoking deletes the key and writes the registry: only the credential owner may.
        guard model.isCredentialOwner else {
            failure = .error(CredentialOwnershipError.notOwner(operation: "unpair this Mac").description)
            return
        }
        let mutation = NodeMutation(Ws.Device.Revoke.self, on: queries, invalidating: ["device.list"])
        guard await mutation.run(.init(deviceID: deviceID)) != nil else {
            failure = mutation.error ?? .error("\(node.displayName) asked for a confirmation this version can't give.")
            return
        }
        // The node revoked this Mac: stop its session, delete its key, and record it as unpaired.
        model.prepareForPairing(id)
        try? await model.deviceKeys?.deleteIdentity(for: id.rawValue)
        model.updatePairing(.unpaired, for: id)
    }
}
