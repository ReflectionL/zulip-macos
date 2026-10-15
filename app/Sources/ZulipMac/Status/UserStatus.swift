import SwiftUI
import ZulipCoreBindings

/// What a user says about themselves (Zulip's user status): a short text and an
/// emoji, either of which may be empty.
struct UserStatusDisplay: Equatable, Sendable {
    /// Zulip rejects longer texts. It counts Unicode code points, so one emoji
    /// built from several (a family, a flag) counts as more than one.
    static let maximumTextLength = 60

    /// `text` cut to whole characters that fit Zulip's limit.
    static func clampedText(_ text: String) -> String {
        guard text.unicodeScalars.count > maximumTextLength else {
            return text
        }
        var result = ""
        var used = 0
        for character in text {
            used += character.unicodeScalars.count
            if used > maximumTextLength {
                break
            }
            result.append(character)
        }
        return result
    }

    var text: String
    var emojiName: String
    var emojiCode: String
    var reactionType: String

    init(text: String = "", emoji: ReactionTarget? = nil) {
        self.text = text
        emojiName = emoji?.name ?? ""
        emojiCode = emoji?.code ?? ""
        reactionType = emoji == nil ? "" : (emoji?.type ?? "unicode_emoji")
    }

    init(_ status: LiveUserStatus) {
        text = status.text
        emojiName = status.emojiName
        emojiCode = status.emojiCode
        reactionType = status.reactionType
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && emojiName.isEmpty
    }

    var emoji: ReactionTarget? {
        emojiName.isEmpty
            ? nil
            : ReactionTarget(
                name: emojiName,
                code: emojiCode,
                type: reactionType.isEmpty ? "unicode_emoji" : reactionType
            )
    }

    /// The emoji as characters; nil when there is none or it is an organization's
    /// custom emoji, which has no glyph here.
    var glyph: String? {
        guard !emojiName.isEmpty else {
            return nil
        }
        if reactionType.isEmpty || reactionType == "unicode_emoji" {
            if let glyph = EmojiCatalog.glyph(forCode: emojiCode) {
                return glyph
            }
            return EmojiCatalog.all.first { $0.name == emojiName }?.glyph
        }
        return nil
    }

    /// "🏠 Working remotely", or whichever half is set.
    var summary: String {
        [glyph, text.isEmpty ? nil : text].compactMap { $0 }.joined(separator: " ")
    }

    /// The choices Zulip's web app offers, with its emoji names.
    static let suggestions: [UserStatusDisplay] = [
        suggestion("In a meeting", name: "calendar", code: "1f4c6"),
        suggestion("Commuting", name: "bus", code: "1f68c"),
        suggestion("Out sick", name: "sick", code: "1f912"),
        suggestion("Vacationing", name: "palm_tree", code: "1f334"),
        suggestion("Working remotely", name: "house", code: "1f3e0"),
        suggestion("At the office", name: "office", code: "1f3e2"),
    ]

    private static func suggestion(_ text: String, name: String, code: String) -> UserStatusDisplay {
        UserStatusDisplay(text: text, emoji: ReactionTarget(name: name, code: code))
    }
}

/// The emoji of someone's status, small, after their name.
struct UserStatusEmoji: View {
    let status: UserStatusDisplay?
    var size: CGFloat = 12

    var body: some View {
        if let status, let glyph = status.glyph {
            Text(glyph)
                .font(.system(size: size * InterfaceScale.shared.factor))
                .help(status.text.isEmpty ? ":\(status.emojiName):" : status.text)
                .accessibilityLabel("Status: \(status.text.isEmpty ? status.emojiName : status.text)")
        }
    }
}

/// What the profile button in the sidebar can show and change.
struct ProfileStatusControl {
    let status: UserStatusDisplay?
    let isInvisible: Bool
    let editStatus: () -> Void
    let clearStatus: () -> Void
    let setInvisible: (Bool) -> Void
}

/// The popover behind the user's own avatar: their status, and invisible mode.
struct ProfileStatusPopover: View {
    let name: String
    let avatar: AnyView
    let control: ProfileStatusControl
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            HStack(spacing: AppTheme.Spacing.small) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(AppTheme.Typography.bodyEmphasized)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(
                                control.isInvisible
                                    ? AppTheme.Colors.tertiaryText
                                    : AppTheme.Colors.success
                            )
                            .frame(width: 7, height: 7)
                        Text(control.isInvisible ? "Invisible" : "Active")
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    }
                }
            }

            Divider()

            if let status = control.status, !status.isEmpty {
                HStack(spacing: AppTheme.Spacing.small) {
                    Button {
                        close()
                        control.editStatus()
                    } label: {
                        Text(status.summary.isEmpty ? ":\(status.emojiName):" : status.summary)
                            .font(AppTheme.Typography.body)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit status")

                    Button {
                        control.clearStatus()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .help("Clear status")
                    .accessibilityLabel("Clear status")
                }
            } else {
                Button {
                    close()
                    control.editStatus()
                } label: {
                    Label("Set a status", systemImage: "face.smiling")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            Toggle(
                isOn: Binding(
                    get: { control.isInvisible },
                    set: control.setInvisible
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invisible mode")
                    Text("Others see you as offline.")
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(AppTheme.Spacing.large)
        .frame(width: 280)
    }
}

/// Sets the user's status: an emoji, a short text, or one of Zulip's suggestions.
struct UserStatusEditor: View {
    let initial: UserStatusDisplay?
    let save: (UserStatusDisplay) -> Void
    let dismiss: () -> Void

    @State private var text: String
    @State private var emoji: ReactionTarget?
    @State private var isChoosingEmoji = false
    @FocusState private var isTextFocused: Bool

    init(
        initial: UserStatusDisplay?,
        save: @escaping (UserStatusDisplay) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.initial = initial
        self.save = save
        self.dismiss = dismiss
        _text = State(initialValue: initial?.text ?? "")
        _emoji = State(initialValue: initial?.emoji)
    }

    private var draft: UserStatusDisplay {
        UserStatusDisplay(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji
        )
    }

    private var hasInitialStatus: Bool {
        !(initial?.isEmpty ?? true)
    }

    private var canSave: Bool {
        draft.text.unicodeScalars.count <= UserStatusDisplay.maximumTextLength
            && draft != (initial ?? UserStatusDisplay())
            && !(draft.isEmpty && !hasInitialStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            Text(hasInitialStatus ? "Edit status" : "Set a status")
                .font(AppTheme.Typography.title)

            HStack(spacing: AppTheme.Spacing.small) {
                Button {
                    isChoosingEmoji = true
                } label: {
                    Group {
                        if let glyph = draft.glyph {
                            Text(glyph)
                                .font(.system(size: 18))
                        } else {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.hover, in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Choose an emoji")
                .accessibilityLabel("Choose an emoji")
                .popover(isPresented: $isChoosingEmoji, arrowEdge: .bottom) {
                    ReactionPicker(existing: []) { chosen in
                        emoji = chosen
                        isChoosingEmoji = false
                    }
                }
                .contextMenu {
                    if emoji != nil {
                        Button("Remove Emoji") { emoji = nil }
                    }
                }

                TextField("What’s your status?", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFocused)
                    .onSubmit {
                        if canSave { submit() }
                    }
                    .onChange(of: text) {
                        let clamped = UserStatusDisplay.clampedText(text)
                        if clamped != text {
                            text = clamped
                        }
                    }

                if !draft.isEmpty {
                    Button {
                        text = ""
                        emoji = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .help("Clear")
                    .accessibilityLabel("Clear text and emoji")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(UserStatusDisplay.suggestions, id: \.text) { suggestion in
                    Button {
                        text = suggestion.text
                        emoji = suggestion.emoji
                    } label: {
                        Text(suggestion.summary)
                            .font(AppTheme.Typography.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AppTheme.Spacing.small)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SuggestionButtonStyle())
                }
            }

            HStack {
                if hasInitialStatus {
                    Button("Clear Status", role: .destructive) {
                        save(UserStatusDisplay())
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(28)
        .frame(width: 400)
        .onAppear { isTextFocused = true }
    }

    private func submit() {
        save(draft)
        dismiss()
    }
}

/// A full-width row that lights up under the pointer.
private struct SuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SuggestionRow(configuration: configuration)
    }

    private struct SuggestionRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            configuration.isPressed
                                ? AppTheme.Colors.selection
                                : isHovered ? AppTheme.Colors.hover : .clear
                        )
                )
                .onHover { isHovered = $0 }
        }
    }
}
