import AppKit
import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// The chrome every mirror action sheet shares: a tinted icon, the console's title and consequence text, the body,
/// then the buttons at the bottom right. A destructive sheet is red from its icon on, so it can't be mistaken for an
/// ordinary one; nothing in it moves or flashes.
struct MirrorActionSheet<Content: View, Buttons: View>: View {
    var destructive = false
    var systemImage: String
    var title: String
    var description: String?
    var width: CGFloat = 540
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        let tone: StatusTone = destructive ? .danger : .info
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(destructive ? tone.color : Color.accentText)
                    .frame(width: 40, height: 40)
                    .background(destructive ? tone.soft : Color.accentSoft,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(destructive ? tone.line : Color.accentLine, lineWidth: 1)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                buttons
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(width: width)
    }
}

/// The button that runs a sheet's action. Never the default (Return) button: a mirror action runs only on a click.
struct MirrorActionButton: View {
    var label: String
    var destructive = false
    var running = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.small) }
                Text(label)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(destructive ? StatusTone.danger.color : nil)
        .disabled(!enabled || running)
    }
}

/// "Keep it" / "Done" / "Close": closes the sheet (Esc). Disabled while the action runs, so an answer is never lost.
struct MirrorCloseButton: View {
    var label: String = MirrorCopy.keepGoing
    var disabled = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(label, role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
            .disabled(disabled)
    }
}

/// A refusal in the server's own sentence under the console's heading for it ("The vault was not detached"). A
/// step-up or approval this Mac can't give is said plainly, with the server's message.
struct MirrorRefusal: View {
    var title: String
    var error: WsError?

    var body: some View {
        if let error {
            Callout(tone: tone(error), systemImage: QueryProblem(error) == .noAnswerYet ? "hourglass" : "exclamationmark.circle") {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.fg)
                Text(Self.sentence(error))
                    .foregroundStyle(.fgMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tone(_ error: WsError) -> StatusTone {
        switch QueryProblem(error) {
        case .noAnswerYet, .offline: .info
        case .denied: .warn
        default: .danger
        }
    }

    static func sentence(_ error: WsError) -> String {
        switch error {
        case .stepUpRequired(_, let message):
            return "\(message) This Mac can’t give that approval."
        case .denied(let message):
            return "Not allowed: \(message)"
        default:
            switch QueryProblem(error) {
            case .noAnswerYet: return "No answer yet. The node may still be working on it; check before trying again."
            case .offline: return "Not connected to the node. Nothing was changed."
            case .failed(let message), .notFound(let message): return message
            default: return error.message
            }
        }
    }
}

/// "Type “Photos” to confirm" and its field. The field is never filled in for the person.
struct MirrorTypedName: View {
    var label: String
    var name: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.fg)
            // No placeholder: the vault's name greyed in the field would read as already typed.
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
        }
    }
}

/// A labelled field with a hint under it (the console's Field).
struct MirrorField<Control: View>: View {
    var label: String
    var hint: String?
    var error: String?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.fg)
            control
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(StatusTone.danger.color)
            } else if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The account that owns what an action makes (detach, detach a copy): this account by default ("You (cooper)"),
/// or another sign-in account here. A picker when this account may list accounts, a name field otherwise.
struct MirrorOwnerField: View {
    var queries: NodeQueries
    var label: String
    var hint: String
    @Binding var owner: String

    var body: some View {
        let me = queries.query(Ws.Auth.IsAuthenticated.self).value?.user?.name ?? ""
        let list = queries.query(Ws.Auth.Users.List.self)
        let others = (list.value?.users ?? []).filter { !$0.systemOnly && $0.name != me }.map(\.name)
        MirrorField(label: label, hint: hint) {
            if list.value != nil {
                Picker(label, selection: $owner) {
                    Text(MirrorCopy.detachOwnerMe(me)).tag("")
                    ForEach(others, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            } else {
                TextField("", text: $owner, prompt: Text(MirrorCopy.detachOwnerMe(me)))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 320)
            }
        }
        .observing(queries.query(Ws.Auth.IsAuthenticated.self))
        .observing(list)
    }
}

/// Two or more choices as cards, one picked (the console's ChoiceCards). Nothing is picked for the person unless
/// the caller passes a value, which is only ever the choice that keeps data.
struct MirrorChoiceCards<Value: Hashable>: View {
    struct Option: Identifiable {
        var value: Value
        var title: String
        var hint: String
        var id: Value { value }
    }

    var legend: String
    var options: [Option]
    @Binding var selection: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(legend)
                .font(.callout.weight(.medium))
                .foregroundStyle(.fg)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(options) { option in
                let picked = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 14))
                            .foregroundStyle(picked ? Color.accentText : Color.fgSubtle)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.fg)
                            Text(option.hint)
                                .font(.caption)
                                .foregroundStyle(.fgMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(picked ? Color.accentSoft : Color.surface1,
                                in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous)
                            .strokeBorder(picked ? Color.accentLine : Color.line, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? [.isSelected] : [])
            }
        }
    }
}

/// A warning box with a heading (the console's warn panels: missing files, files left out, the take over's).
struct MirrorWarning<Trailing: View, Content: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StatusTone.warn.color)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(StatusTone.warn.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing
            }
            content
                .font(.callout)
                .foregroundStyle(.fgMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StatusTone.warn.soft, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous)
                .strokeBorder(StatusTone.warn.line, lineWidth: 1)
        }
    }
}

extension MirrorWarning where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = EmptyView()
        self.content = content()
    }
}

/// A bulleted list of sentences.
struct MirrorBullets: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.fgSubtle)
                    Text(line)
                        .foregroundStyle(.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }
}

/// Paths with their sizes in a small scrolling box (missing files, files left out).
struct MirrorPathList: View {
    struct Item: Identifiable {
        var id: String
        var path: String
        var detail: String
    }

    var items: [Item]
    var more: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(item.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.fgMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.path)
                        Spacer(minLength: 8)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                            .monospacedDigit()
                    }
                }
                if let more {
                    Text(more)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Color.line, lineWidth: 1)
        }
    }
}

/// Copies text (a list of paths) to the pasteboard, and says so.
struct MirrorCopyListButton: View {
    var label: String
    var text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.clipboard")
        }
        .controlSize(.small)
    }
}

/// A progress bar: accent on a quiet track; indeterminate while the total is unknown.
struct MirrorProgressBar: View {
    var ratio: Double?
    var label: String

    var body: some View {
        Group {
            if let ratio {
                ProgressView(value: min(max(ratio, 0), 1))
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .tint(.accentFill)
        .accessibilityLabel(label)
    }
}

/// An outcome's heading and sentences, in a quiet panel (the console's result block).
struct MirrorOutcome<Content: View>: View {
    var label: String
    var tone: StatusTone
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusBadge(label: label, tone: tone)
            VStack(alignment: .leading, spacing: 6) { content }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
