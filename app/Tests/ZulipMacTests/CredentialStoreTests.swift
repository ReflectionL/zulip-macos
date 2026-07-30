import Foundation
import Security
import Testing
@testable import ZulipCoreBindings

@Suite("Keychain credential store")
struct CredentialStoreTests {
    @Test("New credentials are stored without exposing them in debug output")
    func saveAndRedact() async throws {
        let backend = RecordingKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        let credential = StoredAPICredential(
            accountID: "account-01",
            apiKey: "secret-api-key"
        )

        try await store.save(credential)

        let request = try #require(backend.added.first)
        #expect(request.account == "account-01")
        #expect(request.service.hasSuffix(".api-key"))
        #expect(String(data: try #require(request.value), encoding: .utf8) == "secret-api-key")
        #expect(!String(describing: credential).contains("secret-api-key"))
        #expect(!String(reflecting: credential).contains("secret-api-key"))
        #expect(String(reflecting: credential).contains("[REDACTED]"))
    }

    @Test("Duplicate credentials are updated in place")
    func duplicateUpdate() async throws {
        let backend = RecordingKeychainBackend(addStatus: errSecDuplicateItem)
        let store = KeychainCredentialStore(backend: backend)

        try await store.save(
            StoredAPICredential(accountID: "account-02", apiKey: "replacement")
        )

        #expect(backend.added.count == 1)
        #expect(backend.updated.count == 1)
        #expect(backend.deleted.isEmpty)
    }

    @Test("Credentials load and deletion are account scoped")
    func loadAndDelete() async throws {
        let backend = RecordingKeychainBackend(
            copiedData: Data("stored-key".utf8)
        )
        let store = KeychainCredentialStore(backend: backend)

        let credential = try await store.load(accountID: "account-03")
        try await store.delete(accountID: "account-03")

        #expect(credential.accountID == "account-03")
        #expect(credential.apiKey == "stored-key")
        #expect(backend.copied.map(\.account) == ["account-03"])
        #expect(backend.deleted.map(\.account) == ["account-03"])
    }

    @Test("Missing credentials use a stable non-secret error")
    func missingCredential() async {
        let backend = RecordingKeychainBackend(copyStatus: errSecItemNotFound)
        let store = KeychainCredentialStore(backend: backend)

        await #expect(throws: CredentialStoreError.notFound) {
            try await store.load(accountID: "missing")
        }
    }
}

private final class RecordingKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let addStatus: OSStatus
    private let copyStatus: OSStatus
    private let copiedData: Data?

    private(set) var added: [KeychainRequest] = []
    private(set) var updated: [KeychainRequest] = []
    private(set) var copied: [KeychainRequest] = []
    private(set) var deleted: [KeychainRequest] = []

    init(
        addStatus: OSStatus = errSecSuccess,
        copyStatus: OSStatus = errSecSuccess,
        copiedData: Data? = nil
    ) {
        self.addStatus = addStatus
        self.copyStatus = copyStatus
        self.copiedData = copiedData
    }

    func add(_ request: KeychainRequest) -> OSStatus {
        lock.withLock {
            added.append(request)
        }
        return addStatus
    }

    func update(_ request: KeychainRequest) -> OSStatus {
        lock.withLock {
            updated.append(request)
        }
        return errSecSuccess
    }

    func copy(_ request: KeychainRequest) -> (OSStatus, Data?) {
        lock.withLock {
            copied.append(request)
        }
        return (copyStatus, copiedData)
    }

    func delete(_ request: KeychainRequest) -> OSStatus {
        lock.withLock {
            deleted.append(request)
        }
        return errSecSuccess
    }
}
