import Testing
@testable import ZulipMac
import ZulipCoreBindings

@Suite("Application identity")
struct AppIdentityTests {
    @Test("The foundation target remains macOS-only")
    func targetIdentity() {
        #expect(AppIdentity.displayName == "Zulip Mac")
        #expect(AppIdentity.minimumSystem == "macOS 26")
        #expect(AppIdentity.bundleIdentifier.hasPrefix("io.github."))
    }

    @Test("Swift commands round-trip through the Rust core")
    func rustBridgeRoundTrip() async {
        let client = LiveCoreClient()
        var events = client.events.makeAsyncIterator()

        client.submit(
            BridgeCommand(requestID: 42, payload: "bridge smoke test")
        )

        let event = await events.next()
        #expect(event?.requestID == 42)
        #expect(event?.message.hasSuffix("received: bridge smoke test") == true)
    }

    @Test("Live commands redact credentials and reject unsupported routes locally")
    func liveCommandSafety() async {
        let command = BridgeCommand.startAPIKeySession(
            requestID: 43,
            accountID: "account-1",
            serverURL: "https://example.com",
            email: "maya@example.com",
            apiKey: "secret-that-must-not-appear"
        )
        #expect(!String(describing: command).contains("secret-that-must-not-appear"))
        #expect(!String(reflecting: command).contains("secret-that-must-not-appear"))

        let passwordCommand = BridgeCommand.startPasswordSession(
            requestID: 45,
            accountID: "account-1",
            serverURL: "https://example.com",
            username: "maya@example.com",
            password: "password-that-must-not-appear"
        )
        #expect(!String(describing: passwordCommand).contains("password-that-must-not-appear"))
        #expect(!String(reflecting: passwordCommand).contains("password-that-must-not-appear"))

        let client = LiveCoreClient()
        var events = client.events.makeAsyncIterator()
        client.submit(
            .openConversation(
                requestID: 44,
                key: .mentions(accountID: "account-1"),
                limit: 50
            )
        )

        let event = await events.next()
        #expect(event?.requestID == 44)
        #expect(event?.message.contains("not available") == true)
    }
}
