import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VHCloud
import VHRecovery

/// Settings → Cloud: this Mac as an optional Vaulthalla Cloud installation, and delivering vault keys to a server that
/// restores a vault through the cloud (vaulthalla-cloud docs/design/recovery-restore.md). Hidden until the service
/// opens: `defaults write sh.vaulthalla.app cloud.enabled -bool YES` shows it (SettingsView).
struct CloudSettingsView: View {
    @State private var model = CloudSettingsModel()

    var body: some View {
        Form {
            switch model.phase {
            case .unlinked:
                Section {
                    TextField("Name", text: $model.name, prompt: Text(Host.current().localizedName ?? "This Mac"))
                    TextField("Endpoint", text: $model.endpoint)
                    Button("Link This Mac") { Task { await model.link() } }
                        .disabled(model.busy)
                } header: {
                    Text("Vaulthalla Cloud")
                } footer: {
                    Text("Optional. Linking lets this Mac deliver a vault's keys, from your recovery kit, to a server you restore it on. Nothing else in Vaulthalla needs it.")
                        .foregroundStyle(.secondary)
                }
            case let .pending(code, fingerprint):
                Section("Approve on vaulthalla.cloud") {
                    LabeledContent("Code") { Text(code).font(.title2.monospaced()).textSelection(.enabled) }
                    LabeledContent("Key fingerprint") { Text(fingerprint).font(.body.monospaced()).textSelection(.enabled) }
                    Text("Sign in on vaulthalla.cloud, choose Link a device, enter the code and check that it shows this fingerprint before you approve.")
                        .foregroundStyle(.secondary)
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for approval…").foregroundStyle(.secondary)
                    }
                }
            case .linked:
                Section("Vaulthalla Cloud") {
                    LabeledContent("Linked as", value: model.name)
                    Button("Unlink This Mac…", role: .destructive) { model.confirmingUnlink = true }
                }
                restoresSection
            }
            if let message = model.message {
                Section { Text(message).foregroundStyle(model.messageIsError ? .orange : .secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 260)
        .task { await model.load() }
        .confirmationDialog("Unlink this Mac from Vaulthalla Cloud?", isPresented: $model.confirmingUnlink,
                            titleVisibility: .visible) {
            Button("Unlink", role: .destructive) { Task { await model.unlink() } }
        } message: {
            Text("It stops being able to deliver vault keys for restores. Link again any time.")
        }
        .confirmationDialog("Does the server show this restore code?", isPresented: $model.confirmingDelivery,
                            titleVisibility: .visible, presenting: model.selected) { restore in
            Button("Yes, \(restore.restoreCode): Deliver") { Task { await model.deliver(restore) } }
            Button("No", role: .cancel) {}
        } message: { restore in
            Text("The server restoring vault \(restore.vaultUid) must show \(restore.restoreCode). If it shows anything else, don't deliver: someone may be trying to receive the keys instead.")
        }
    }

    private var restoresSection: some View {
        Section {
            if model.restores.isEmpty {
                Text("No restore is waiting for a device.").foregroundStyle(.secondary)
            }
            ForEach(model.restores, id: \.id) { restore in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vault \(restore.vaultUid)").font(.headline)
                    Text("To the \(restore.requesterKind) \u{201C}\(restore.requesterName)\u{201D} (key \(restore.requesterFingerprint))")
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(restore.restoreCode).font(.title3.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Deliver from Recovery Kit…") { model.choose(restore) }
                            .disabled(model.busy)
                    }
                }
                .padding(.vertical, 4)
            }
            Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy)
        } header: {
            Text("Restores waiting for this Mac")
        } footer: {
            Text("Approved on vaulthalla.cloud, for vaults whose recovery kit you hold. Delivering re-wraps the vault's keys to the restoring server's temporary key; vaulthalla.cloud can't open them.")
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
@Observable
final class CloudSettingsModel {
    enum Phase: Equatable { case unlinked, pending(code: String, fingerprint: String), linked }

    var phase: Phase = .unlinked
    var name = Host.current().localizedName ?? "This Mac"
    var endpoint = UserDefaults.standard.string(forKey: "cloud.endpoint") ?? "https://api.vaulthalla.cloud"
    var restores: [CloudClient.Restore] = []
    var selected: CloudClient.Restore?
    var kit: RecoveryKit?
    var busy = false
    var confirmingUnlink = false
    var confirmingDelivery = false
    var message: String?
    var messageIsError = false

    private let store = KeychainCloudLinkStore()

    private func client() throws -> CloudClient { try CloudClient(endpoint: endpoint, store: store) }

    private func report(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    func load() async {
        guard let link = try? store.load() else { return }
        endpoint = link.endpoint
        name = link.name
        if link.state == .linked {
            phase = .linked
            await refresh()
        }
    }

    func link() async {
        busy = true
        defer { busy = false }
        do {
            let c = try client()
            let started = try await c.startLink(name: name)
            UserDefaults.standard.set(endpoint, forKey: "cloud.endpoint")
            phase = .pending(code: started.userCode, fingerprint: started.fingerprint)
            message = nil
            while case .pending = phase {
                try await Task.sleep(for: .seconds(3))
                switch try await c.claimLink() {
                case .pending: continue
                case .linked:
                    phase = .linked
                    report("This Mac is linked.")
                    await refresh()
                case .denied:
                    phase = .unlinked
                    report("The link was denied on vaulthalla.cloud.", error: true)
                case .expired:
                    phase = .unlinked
                    report("The code expired. Link again.", error: true)
                }
            }
        } catch {
            phase = .unlinked
            report("Couldn't link: \(error)", error: true)
        }
    }

    func unlink() async {
        do {
            try await client().unlink()
            phase = .unlinked
            restores = []
            report("This Mac is no longer linked.")
        } catch {
            report("Couldn't unlink: \(error)", error: true)
        }
    }

    func refresh() async {
        do {
            restores = try await client().deliverable()
        } catch {
            report("Couldn't list restores: \(error)", error: true)
        }
    }

    /// Picks the recovery kit, then asks the person to compare the code before anything is sent.
    func choose(_ restore: CloudClient.Restore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the recovery kit of vault \(restore.vaultUid)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            kit = try RecoveryKit(json: Data(contentsOf: url))
            selected = restore
            confirmingDelivery = true
        } catch {
            report("That file isn't a recovery kit: \(error)", error: true)
        }
    }

    func deliver(_ restore: CloudClient.Restore) async {
        guard let kit else { return }
        busy = true
        defer {
            busy = false
            self.kit = nil
        }
        do {
            let d = try await client().deliver(restore, kit: kit)
            let missing = d.missing.isEmpty ? "" : " Versions \(d.missing.map(String.init).joined(separator: ", ")) weren't in this kit."
            report("Delivered \(d.versions.count) key version(s) to \u{201C}\(restore.requesterName)\u{201D}.\(missing)")
            await refresh()
        } catch CloudError.noEnvelopeOpens {
            report("This recovery kit doesn't open any of this vault's keys.", error: true)
        } catch CloudError.restoreCodeMismatch {
            report("The restore changed since it was listed, or the cloud's code doesn't match its key. Nothing was sent.", error: true)
            await refresh()
        } catch {
            report("Couldn't deliver: \(error)", error: true)
        }
    }
}
