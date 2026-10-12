import SwiftUI
import ZulipCoreBindings

/// Asks for a channel's new name; the server decides whether the user may rename it.
struct RenameChannelSheet: View {
    let session: LiveSessionViewModel
    let channel: ChannelSnapshot
    let dismiss: () -> Void

    @State private var name: String

    init(
        session: LiveSessionViewModel,
        channel: ChannelSnapshot,
        dismiss: @escaping () -> Void
    ) {
        self.session = session
        self.channel = channel
        self.dismiss = dismiss
        _name = State(initialValue: channel.name)
    }

    private var isRenaming: Bool {
        session.channelRenameState == .renaming
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
                Text("Rename channel")
                    .font(AppTheme.Typography.title)
                Text("Everyone in the organization sees the new name. Only people the server allows can rename a channel.")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Channel name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            if case let .failed(message) = session.channelRenameState {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    session.resetChannelRename()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if isRenaming {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Rename", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedName == channel.name || isRenaming)
            }
        }
        .padding(28)
        .frame(width: 440)
        .interactiveDismissDisabled(isRenaming)
        .onAppear {
            session.resetChannelRename()
        }
        .onChange(of: session.channelRenameState) {
            if case .renamed = session.channelRenameState {
                session.resetChannelRename()
                dismiss()
            }
        }
    }

    private func submit() {
        guard !trimmedName.isEmpty, trimmedName != channel.name, !isRenaming else {
            return
        }
        session.renameChannel(streamID: channel.streamID, to: trimmedName)
    }
}
