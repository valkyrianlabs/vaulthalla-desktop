import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
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

private struct GeneralSettingsView: View {
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
            Section {
                Text("Connection, notification and backup settings arrive with pairing.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 220)
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
