import SwiftUI

/// Name, description, visibility and first members of a new channel.
struct CreateChannelSheet: View {
    let session: LiveSessionViewModel
    let dismiss: () -> Void

    @State private var name = ""
    @State private var channelDescription = ""
    @State private var isPrivate = false
    @State private var selectedMembers: Set<Int64> = []
    @State private var memberFilter = ""

    private var isCreating: Bool {
        session.channelCreationState == .creating
    }

    private var visibleMembers: [MentionCandidate] {
        let needle = memberFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return session.channelMemberCandidates
        }
        return session.channelMemberCandidates.filter {
            $0.name.lowercased().contains(needle) || $0.detail.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            Text("New channel")
                .font(AppTheme.Typography.title)

            TextField("Channel name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $channelDescription, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            Toggle("Private channel", isOn: $isPrivate)
            Text(
                isPrivate
                    ? "Only the members you add can see this channel."
                    : "Anyone in the organization can find and join this channel."
            )
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.Colors.secondaryText)

            Text("Add people (\(selectedMembers.count) selected)")
                .font(AppTheme.Typography.bodyStrong)
            TextField("Search people", text: $memberFilter)
                .textFieldStyle(.roundedBorder)
            List(visibleMembers) { person in
                memberRow(person)
            }
            .frame(minHeight: 160, maxHeight: 220)

            if case let .failed(message) = session.channelCreationState {
                Text(message)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") {
                    session.resetChannelCreation()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    session.createChannel(
                        name: name,
                        description: channelDescription,
                        isPrivate: isPrivate,
                        memberIDs: Array(selectedMembers)
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(AppTheme.Spacing.large)
        .frame(width: 440)
        .onAppear {
            session.resetChannelCreation()
        }
        .onChange(of: session.channelCreationState) {
            if case .created = session.channelCreationState {
                session.resetChannelCreation()
                dismiss()
            }
        }
    }

    private func memberRow(_ person: MentionCandidate) -> some View {
        let userID: Int64? = if case let .person(id) = person.kind { id } else { nil }
        let isSelected = userID.map(selectedMembers.contains) ?? false
        return Button {
            guard let userID else { return }
            if isSelected {
                selectedMembers.remove(userID)
            } else {
                selectedMembers.insert(userID)
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.small) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected ? AppTheme.Colors.accent : AppTheme.Colors.tertiaryText
                    )
                Text(person.name)
                Text(person.detail)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
