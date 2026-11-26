import AppKit
import SwiftUI
import VHNodes

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Notifications", systemImage: "bell.badge") {
                NotificationsSettingsView()
            }
            Tab("Agents", systemImage: "sparkles") {
                AgentsSettingsView()
            }
            Tab("1Password", systemImage: "key.horizontal") {
                OnePasswordSettingsView()
            }
            Tab("Finder", systemImage: "folder.badge.gearshape") {
                FinderSettingsView()
            }
            Tab("About", systemImage: "info.circle") {
                AboutView()
            }
        }
        .frame(width: 520)
        .preferredColorScheme(.dark)
        .tint(.accentFill)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Nodes") {
                LabeledContent("Saved nodes") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.registryURL])
                    }
                }
                LabeledContent("Count", value: model.nodes.count.formatted())
            }
            MenuBarSettingsSection()
            SignInSettingsSection()
            UpdateSettingsSection()
            Section("Connections") {
                Text("Each node is reached over the best address that proves its server key: this Mac, the local "
                     + "network, a VPN, then the internet. A node's Overview shows the route in use and why a better "
                     + "one wasn't.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 220)
    }
}

/// The menu bar item and "Open at login" (docs/mac-experience.md §2 to §4).
private struct MenuBarSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MenuBarPreferences.showsItemKey) private var showsItem = true

    var body: some View {
        let login = model.loginItem
        Section("Menu Bar") {
            Toggle(isOn: $showsItem) {
                Text("Show Vaulthalla in the menu bar")
                Text(showsItem
                     ? "Vaulthalla keeps running when its window is closed and watches your nodes from the menu bar."
                     : "Closing the window quits Vaulthalla. Nothing watches your nodes while it isn't open.")
            }
            Toggle(isOn: Binding(get: { login.isEnabled }, set: { login.setEnabled($0) })) {
                Text("Open at login")
                Text(loginCaption(login.status))
            }
            .disabled(!showsItem || login.status == .unavailable)
            if login.status == .requiresApproval {
                LabeledContent("Turned off in System Settings") {
                    Button("Open Login Items…") { MainAppLoginItem.openSystemSettings() }
                }
            }
            if let problem = login.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(StatusTone.warn.color)
            }
        }
        .onChange(of: showsItem) { _, _ in MainWindow.updatePresence() }
        .onChange(of: scenePhase) { _, _ in login.refresh() }
        .onAppear { login.refresh() }
    }

    private func loginCaption(_ status: LoginItemStatus) -> String {
        if !showsItem { return "Needs the menu bar item: without it there is nothing to open into." }
        switch status {
        case .enabled: return "Starts with only the menu bar item, no window. Listed under Login Items in System Settings."
        case .disabled: return "Vaulthalla starts when you open it."
        case .requiresApproval: return "macOS is holding it back until you allow it under Login Items."
        case .unavailable: return "This build can't be a login item."
        }
    }
}

/// "Keep me signed in on this Mac", Sign Out, and the Touch ID gate (desktop#7, SignIn.swift).
private struct SignInSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SignInPreferences.keepSignedInKey) private var keepSignedIn = true
    @State private var confirmingSignOut = false
    @State private var signingOut = false
    @State private var outcome: String?

    var body: some View {
        Section("Sign-In") {
            Toggle(isOn: $keepSignedIn) {
                Text("Keep me signed in on this Mac")
                Text(keepSignedIn
                     ? "Paired nodes stay signed in across quits, restarts and macOS logins."
                     : "Quitting Vaulthalla or logging out of macOS signs this Mac out of every node and removes its vaults from Finder.")
            }
            LabeledContent {
                Button(signingOut ? "Signing Out…" : "Sign Out…", role: .destructive) { confirmingSignOut = true }
                    .disabled(signingOut || !model.isCredentialOwner || !model.hasSignedInNodes)
            } label: {
                Text("Sign out of every node")
                Text("Revokes this Mac on each node and deletes its keys here. Pair again to sign back in.")
            }
        }
        .confirmationDialog("Sign this Mac out of every node?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each node revokes this Mac, its keys are deleted here, and Vaulthalla's vaults leave Finder with the copies downloaded to this Mac, including changes not uploaded yet. The nodes stay listed; pair again to use one.")
        }
        .alert("Signed out", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(outcome ?? "")
        }

        SecuritySettingsSection()
    }

    private func signOut() async {
        signingOut = true
        defer { signingOut = false }
        guard let report = await model.signOut() else { return }
        var lines: [String] = []
        let unreached = report.notRevoked.keys.compactMap { model.node(withID: $0)?.displayName }.sorted()
        if !unreached.isEmpty {
            lines.append("This Mac's keys are deleted, but \(unreached.formatted(.list(type: .and))) couldn't be told. "
                         + "Revoke this Mac there under Devices in the web console.")
        }
        if let problem = report.domainProblem {
            lines.append("Finder's vaults couldn't all be removed: \(problem)")
        }
        outcome = lines.isEmpty ? "Every node revoked this Mac." : lines.joined(separator: "\n\n")
    }
}

private struct SecuritySettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let access = model.sensitiveAccess
        Section("Security") {
            Toggle(isOn: Binding(get: { access.isRequired }, set: { on in Task { await access.setRequired(on) } })) {
                Text("Ask for Touch ID before showing Recovery Keys, Credentials and Access")
                Text("Uses your Mac's password where there's no Touch ID. Locks again when the screen locks or the Mac sleeps. Finder and backups keep working either way.")
            }
            if let problem = access.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(StatusTone.warn.color)
            }
        }
    }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    private var copyright: String? {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Vaulthalla")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.fg)
            Text(version)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.fgSubtle)
                .textSelection(.enabled)
            Text("The native cockpit for your Vaulthalla nodes.")
                .font(.callout)
                .foregroundStyle(.fgMuted)
                .padding(.top, 4)
            if let copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.fgFaint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
        .environment(PreviewSamples.model())
}
#endif
