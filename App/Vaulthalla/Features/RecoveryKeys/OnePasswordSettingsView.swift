import SwiftUI
import VHKeyBackup

/// Settings → 1Password: the account and vault vault keys are backed up to, and the "needs backup" notification.
struct OnePasswordSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var account = ""
    @State private var vaultTitle = ""
    @State private var check: RecoveryKeysModel.AccountCheck?
    @State private var checking = false
    @State private var notificationsDenied = false
    @State private var loaded = false

    private var keys: RecoveryKeysModel { app.recoveryKeys }

    var body: some View {
        Form {
            Section {
                TextField("Account", text: $account, prompt: Text("e.g. My Family"))
                    .onSubmit(save)
                HStack(spacing: 10) {
                    Button("Check") { Task { await runCheck() } }
                        .disabled(trimmedAccount.isEmpty || checking)
                    if checking {
                        ProgressView().controlSize(.small)
                        Text("Waiting for 1Password… approve with Touch ID if it asks.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let check { checkResult(check) }
            } header: {
                Text("1Password account")
            } footer: {
                Text("The account's name exactly as it appears at the top of 1Password's sidebar. Vaulthalla talks to the 1Password app on this Mac; you approve with Touch ID. No token or CLI is needed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Vault", text: $vaultTitle, prompt: Text(OnePasswordSettings.defaultVaultTitle))
                    .onSubmit(save)
            } header: {
                Text("1Password vault")
            } footer: {
                Text("One item per vault and node, holding every key version files still need. The vault is created on the first backup if it doesn't exist.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify me when vault keys need backup", isOn: Binding(
                    get: { keys.notificationsEnabled },
                    set: { enabled in Task { notificationsDenied = !(await keys.setNotifications(enabled)) && enabled } }))
                if notificationsDenied {
                    Text("macOS didn't allow notifications. Turn them on for Vaulthalla in System Settings → Notifications.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Vaulthalla checks every paired node every 5 minutes while it runs. Keys themselves only move when you back up or restore.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 380)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            account = keys.settings.account
            vaultTitle = keys.settings.vaultTitle
        }
        .onDisappear(perform: save)
        .onChange(of: account) { _, _ in check = nil }
    }

    private var trimmedAccount: String { account.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        let title = vaultTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        keys.settings = OnePasswordSettings(account: trimmedAccount,
                                            vaultTitle: title.isEmpty ? OnePasswordSettings.defaultVaultTitle : title)
    }

    private func runCheck() async {
        save()
        checking = true
        defer { checking = false }
        check = await keys.checkAccount(trimmedAccount)
        if case .connected = check { await keys.refreshOnePassword() }
    }

    @ViewBuilder
    private func checkResult(_ check: RecoveryKeysModel.AccountCheck) -> some View {
        switch check {
        case .connected(let count):
            Label("Connected. 1Password shows this Mac \(count == 1 ? "1 vault" : "\(count) vaults").",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(_, let message, let hint):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if let hint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
