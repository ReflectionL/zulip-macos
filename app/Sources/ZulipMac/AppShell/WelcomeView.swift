import AppKit
import SwiftUI

/// The window before an account is connected: the connected window's shell
/// (sidebar, top bar, canvas) with the sign-in form in place of a conversation.
struct WelcomeView: View {
    @Bindable var session: LiveSessionViewModel
    /// True while a saved account is being reconnected after launch.
    let isRestoring: Bool

    var body: some View {
        WindowShellView {
            WelcomeSidebar()
        } content: {
            GeometryReader { proxy in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(AppTheme.Colors.canvas)
            .conversationToolbar(
                title: isRestoring ? "Reconnecting" : "Sign in",
                subtitle: AppIdentity.displayName,
                isOffline: false,
                showsDetails: false
            )
        }
    }

    private var content: some View {
        VStack(spacing: AppTheme.Spacing.extraLarge) {
            VStack(spacing: AppTheme.Spacing.small) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text("Welcome to \(AppIdentity.displayName)")
                    .font(AppTheme.Typography.scaled(22, weight: .semibold))
                Text("Sign in to your Zulip organization.")
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }
            .multilineTextAlignment(.center)

            if isRestoring {
                HStack(spacing: AppTheme.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text(restoringText)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            } else {
                LoginForm(session: session)
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, AppTheme.Spacing.extraLarge)
        .padding(.vertical, AppTheme.Spacing.section)
    }

    private var restoringText: String {
        session.serverURL.isEmpty
            ? "Reconnecting…"
            : "Reconnecting to \(session.serverURL)…"
    }
}

/// Server, email and password or API key, with the connection status and the
/// Connect button. Shared by the welcome window and the sign-in sheet.
struct LoginForm: View {
    @Bindable var session: LiveSessionViewModel

    private enum FocusTarget: Hashable {
        case server
        case email
        case secret
    }

    @FocusState private var focus: FocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            Picker("Authentication", selection: $session.authenticationMethod) {
                ForEach(LiveAuthenticationMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
                inputField("Server", target: .server) {
                    TextField("https://your-org.zulipchat.com", text: $session.serverURL)
                        .onSubmit { focus = .email }
                }
                inputField("Email", target: .email) {
                    TextField("you@example.com", text: $session.email)
                        .onSubmit { focus = .secret }
                }
                inputField(session.authenticationMethod.rawValue, target: .secret) {
                    SecureField(
                        session.authenticationMethod == .password ? "Password" : "API key",
                        text: $session.secret
                    )
                    .privacySensitive()
                    .onSubmit(submit)
                }
            }
            .disabled(isConnecting)

            if let message = statusMessage {
                Label(message, systemImage: statusIcon)
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AppTheme.Spacing.small) {
                Button(action: submit) {
                    HStack(spacing: AppTheme.Spacing.small) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isConnecting ? "Signing in…" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isConnecting)

                if session.hasSavedAccount {
                    Button("Use Saved API Key") {
                        Task {
                            await session.connectUsingSavedAPIKey()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(AppTheme.Typography.sidebar)
                    .foregroundStyle(AppTheme.Colors.accent)
                    .disabled(isConnecting)
                }
            }

            Text(storageNote)
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            focus = session.serverURL.isEmpty ? .server : .secret
        }
        .onChange(of: session.connectionState) {
            // The credential is cleared when a sign-in starts, so a failed one
            // is retried by typing it again.
            if case .failed = session.connectionState {
                focus = .secret
            }
        }
    }

    private var isConnecting: Bool {
        session.connectionState.isConnecting
    }

    /// Return in the last field and the Connect button share this path, so a
    /// second press while signing in cannot start another attempt.
    private func submit() {
        guard !isConnecting else {
            return
        }
        session.connect()
    }

    private func inputField<FieldContent: View>(
        _ title: String,
        target: FocusTarget,
        @ViewBuilder field: () -> FieldContent
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: AppTheme.Metrics.controlRadius,
            style: .continuous
        )
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
            Text(title)
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            field()
                .textFieldStyle(.plain)
                .font(AppTheme.Typography.body)
                .focused($focus, equals: target)
                .padding(.horizontal, AppTheme.Spacing.medium)
                .frame(minHeight: 34)
                .background(AppTheme.Colors.elevated, in: shape)
                .overlay {
                    shape.strokeBorder(
                        focus == target
                            ? AppTheme.Colors.accent.opacity(0.7)
                            : AppTheme.Colors.subtleStroke,
                        lineWidth: AppTheme.Metrics.hairline
                    )
                }
                .contentShape(shape)
                .onTapGesture { focus = target }
        }
    }

    private var storageNote: String {
        switch session.authenticationMethod {
        case .password:
            "Your password is never stored. The API key it returns is saved in your Mac’s Keychain."
        case .apiKey:
            "Your API key is saved in your Mac’s Keychain."
        }
    }

    private var statusMessage: String? {
        switch session.connectionState {
        case let .failed(message):
            message
        case let .retrying(delay):
            "Connection interrupted. Retrying in \(delay) ms."
        default:
            session.notice
        }
    }

    private var statusIcon: String {
        if case .failed = session.connectionState {
            return "exclamationmark.triangle"
        }
        return "info.circle"
    }

    private var statusColor: Color {
        if case .failed = session.connectionState {
            return AppTheme.Colors.destructive
        }
        return AppTheme.Colors.secondaryText
    }
}

/// The sidebar column before sign-in: the connected sidebar's header and
/// footer, with nothing between them yet.
private struct WelcomeSidebar: View {
    @Environment(UpdateController.self) private var updates: UpdateController?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.small) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(AppIdentity.displayName)
                        .font(AppTheme.Typography.sidebarEmphasized)
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .lineLimit(1)
                    Text("Not connected")
                        .font(AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 36)
            .padding(.horizontal, AppTheme.Spacing.medium)
            .padding(.top, AppTheme.Metrics.sidebarTopInset)
            .padding(.bottom, AppTheme.Spacing.small)

            Spacer()

            HStack {
                Spacer()
                Menu {
                    if let release = updates?.availableRelease {
                        SettingsLink {
                            Label("Update to \(release.version)…", systemImage: "arrow.down.circle")
                        }
                    }

                    SettingsLink {
                        Label("Settings…", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(AppTheme.Typography.scaled(12))
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, AppTheme.Spacing.small)
            .frame(minHeight: 36)
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    WelcomeView(session: LiveSessionViewModel(), isRestoring: false)
        .frame(width: 1_080, height: 720)
}

#Preview("Welcome — reconnecting") {
    WelcomeView(session: LiveSessionViewModel(), isRestoring: true)
        .frame(width: 1_080, height: 720)
}
#endif
