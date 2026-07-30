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
        let dataProtectionStatus = SecItemAdd(
            addQuery(request, value: value, dataProtection: true) as CFDictionary,
            nil
        )
        guard dataProtectionStatus == errSecMissingEntitlement else {
            return dataProtectionStatus
        }
        return SecItemAdd(
            addQuery(request, value: value, dataProtection: false) as CFDictionary,
            nil
        )
    }

    func update(_ request: KeychainRequest) -> OSStatus {
        guard let value = request.value else {
            return errSecParam
        }
        let attributes = [kSecValueData as String: value] as CFDictionary
        let dataProtectionStatus = SecItemUpdate(
            baseQuery(request, dataProtection: true) as CFDictionary,
            attributes
        )
        guard shouldTryFileKeychain(after: dataProtectionStatus) else {
            return dataProtectionStatus
        }
        return SecItemUpdate(
            baseQuery(request, dataProtection: false) as CFDictionary,
            attributes
        )
    }

    func copy(_ request: KeychainRequest) -> (OSStatus, Data?) {
        let dataProtectionResult = copy(request, dataProtection: true)
        guard shouldTryFileKeychain(after: dataProtectionResult.0) else {
            return dataProtectionResult
        }
        return copy(request, dataProtection: false)
    }

    func delete(_ request: KeychainRequest) -> OSStatus {
        let dataProtectionStatus = SecItemDelete(
            baseQuery(request, dataProtection: true) as CFDictionary
        )
        guard shouldTryFileKeychain(after: dataProtectionStatus) else {
            return dataProtectionStatus
        }
        return SecItemDelete(
            baseQuery(request, dataProtection: false) as CFDictionary
        )
    }

    private func copy(
        _ request: KeychainRequest,
        dataProtection: Bool
    ) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery(request, dataProtection: dataProtection)
                .merging([
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]) { _, new in new } as CFDictionary,
            &result
        )
        return (status, result as? Data)
    }

    private func addQuery(
        _ request: KeychainRequest,
        value: Data,
        dataProtection: Bool
    ) -> [String: Any] {
        var query = baseQuery(request, dataProtection: dataProtection)
        query[kSecValueData as String] = value
        if dataProtection {
            query[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return query
    }

    private func baseQuery(
        _ request: KeychainRequest,
        dataProtection: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: request.service,
            kSecAttrAccount as String: request.account,
        ]
        if dataProtection {
            query[kSecAttrSynchronizable as String] = false
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func shouldTryFileKeychain(after status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecItemNotFound
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
