import AppKit
import SwiftUI
import VHCore
import VHReports

/// Filing a report (docs/mac-experience.md §8): the bundle, readable before anything else can happen, then Save, Copy
/// Summary and, only while this Mac is linked to Vaulthalla Cloud, Send. Nothing here makes a network call except
/// Send, and Send happens once per press.
struct ReportSheet: View {
    var request: ReportRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var report: ReportDocument?
    @State private var reportID = UUID()
    @State private var selected: String?
    @State private var sending = false
    @State private var receipt: ReportReceipt?
    @State private var problem: String?
    @State private var saved: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let report {
                content(report)
            } else {
                ProgressView("Gathering…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 600)
        .background(Color.canvasRaised)
        .preferredColorScheme(.dark)
        .task { rebuild() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Report a Problem")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.fg)
            Text("This is everything the report holds. Names of your nodes, vaults, people and devices, addresses and "
                 + "ids were replaced with labels before you saw it. File contents, file names and keys are never "
                 + "collected.")
                .font(.callout)
                .foregroundStyle(.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func content(_ report: ReportDocument) -> some View {
        HSplitView {
            List(selection: $selected) {
                Label("Summary", systemImage: "doc.text").tag("summary")
                ForEach(report.evidence, id: \.name) { part in
                    Label(part.name, systemImage: part.mediaType == "text/plain" ? "text.alignleft" : "curlybraces")
                        .tag(part.name)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)

            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(text(of: selected ?? "summary", in: report))
                        .font(.callout.monospaced())
                        .foregroundStyle(.fg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .background(Color.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                TextField("Anything to add? (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { rebuild() }
                    .onChange(of: note) { _, _ in rebuild() }
            }
            .padding(14)
            .frame(minWidth: 380)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let receipt {
                    Label("Sent. Reference \(receipt.reference)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(StatusTone.ok.color)
                        .textSelection(.enabled)
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(StatusTone.warn.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let saved {
                    Label("Saved to \(saved.lastPathComponent)", systemImage: "folder")
                        .foregroundStyle(.fgMuted)
                } else if canSend {
                    Text("Sending goes to Valkyrian Labs' own service, signed as this Mac, once, when you press Send.")
                        .foregroundStyle(.fgSubtle)
                } else {
                    Text("The report stays on this Mac. Save it or copy the summary to share it yourself.")
                        .foregroundStyle(.fgSubtle)
                }
            }
            .font(.callout)
            Spacer(minLength: 8)
            Button(receipt == nil ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Copy Summary") { copySummary() }
                .disabled(report == nil)
            Button("Save…") { save() }
                .disabled(report == nil)
            // Absent, not disabled, while this Mac isn't linked: nothing here describes a service it can't use.
            if canSend {
                Button(sending ? "Sending…" : "Send to Valkyrian Labs") { Task { await send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(report == nil || sending || receipt != nil)
            }
        }
        .padding(16)
    }

    private var canSend: Bool { model.cloud?.canSendReports ?? false }

    private func text(of name: String, in report: ReportDocument) -> String {
        if name == "summary" { return ReportBuilder.summary(of: report, reference: receipt?.reference) }
        return report.evidence.first { $0.name == name }?.text ?? ""
    }

    /// Builds the report again (the note changed). The id stays, so sending after an edit is still one report.
    private func rebuild() {
        guard receipt == nil else { return }
        report = ReportBuilder.build(ReportComposer.input(for: request, model: model, note: note), id: reportID)
        if selected == nil { selected = "summary" }
    }

    private func copySummary() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReportBuilder.summary(of: report, reference: receipt?.reference), forType: .string)
    }

    private func save() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.title = "Save Report"
        panel.nameFieldStringValue = "Vaulthalla report \(Date.now.formatted(.iso8601.year().month().day()))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ReportBuilder.write(report, to: url, reference: receipt?.reference)
            saved = url
            problem = nil
        } catch {
            problem = "Couldn't save the report: \(error.localizedDescription)"
        }
    }

    private func send() async {
        guard let report, let cloud = model.cloud else { return }
        sending = true
        defer { sending = false }
        do {
            receipt = try await cloud.sendReport(report)
            problem = nil
        } catch {
            problem = "The report wasn't sent, and is still here to save: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
#Preview("Report · finding") {
    let model = PreviewSamples.liveModel()
    return ReportSheet(request: .init(origin: .node(PreviewSamples.nodes[1].id)))
        .environment(model)
}
#endif
