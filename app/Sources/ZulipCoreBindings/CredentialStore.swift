import Foundation
import Security

public struct StoredAPICredential:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let accountID: String
    public let apiKey: String

    public init(accountID: String, apiKey: String) {
        self.accountID = accountID
        self.apiKey = apiKey
    }

    public var description: String {
        "StoredAPICredential(accountID: \(accountID), apiKey: [REDACTED])"
    }

    public var debugDescription: String {
        description
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case invalidCredential
    case notFound
    case invalidData
    case keychain(OSStatus)
}

public protocol CredentialStore: Sendable {
    func save(_ credential: StoredAPICredential) async throws
    func load(accountID: String) async throws -> StoredAPICredential
    func delete(accountID: String) async throws
}

struct KeychainRequest: Equatable, Sendable {
    let service: String
    let account: String
    var value: Data?
}

protocol KeychainBackend: Sendable {
    func add(_ request: KeychainRequest) -> OSStatus
    func update(_ request: KeychainRequest) -> OSStatus
    func copy(_ request: KeychainRequest) -> (OSStatus, Data?)
    func delete(_ request: KeychainRequest) -> OSStatus
}

struct SecurityKeychainBackend: KeychainBackend {
    func add(_ request: KeychainRequest) -> OSStatus {
        guard let value = request.value else {
            return errSecParam
        }
        return SecItemAdd(
            baseQuery(request)
                .merging([
                    kSecValueData as String: value,
                    kSecAttrAccessible as String:
                        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    kSecUseDataProtectionKeychain as String: true,
                ]) { _, new in new } as CFDictionary,
            nil
        )
    }

    func update(_ request: KeychainRequest) -> OSStatus {
        guard let value = request.value else {
            return errSecParam
        }
        return SecItemUpdate(
            baseQuery(request) as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
    }

    func copy(_ request: KeychainRequest) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery(request)
                .merging([
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]) { _, new in new } as CFDictionary,
            &result
        )
        return (status, result as? Data)
    }

    func delete(_ request: KeychainRequest) -> OSStatus {
        SecItemDelete(baseQuery(request) as CFDictionary)
    }

    private func baseQuery(_ request: KeychainRequest) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: request.service,
            kSecAttrAccount as String: request.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public actor KeychainCredentialStore: CredentialStore {
    private static let service = "io.github.huahai.ZulipMac.api-key"

    private let backend: any KeychainBackend

    public init() {
        backend = SecurityKeychainBackend()
    }

    init(backend: any KeychainBackend) {
        self.backend = backend
    }

    public func save(_ credential: StoredAPICredential) throws {
        guard !credential.accountID.isEmpty,
              !credential.apiKey.isEmpty,
              let data = credential.apiKey.data(using: .utf8)
        else {
            throw CredentialStoreError.invalidCredential
        }

        let request = KeychainRequest(
            service: Self.service,
            account: credential.accountID,
            value: data
        )
        let status = backend.add(request)
        if status == errSecDuplicateItem {
            try check(backend.update(request))
        } else {
            try check(status)
        }
    }

    public func load(accountID: String) throws -> StoredAPICredential {
        guard !accountID.isEmpty else {
            throw CredentialStoreError.invalidCredential
        }

        let request = KeychainRequest(
            service: Self.service,
            account: accountID,
            value: nil
        )
        let (status, data) = backend.copy(request)
        if status == errSecItemNotFound {
            throw CredentialStoreError.notFound
        }
        try check(status)
        guard let data,
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.isEmpty
        else {
            throw CredentialStoreError.invalidData
        }
        return StoredAPICredential(accountID: accountID, apiKey: apiKey)
    }

    public func delete(accountID: String) throws {
        guard !accountID.isEmpty else {
            throw CredentialStoreError.invalidCredential
        }
        let status = backend.delete(
            KeychainRequest(
                service: Self.service,
                account: accountID,
                value: nil
            )
        )
        if status != errSecItemNotFound {
            try check(status)
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
    }
}
