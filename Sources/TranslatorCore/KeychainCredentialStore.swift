import Foundation
import Security

public enum CredentialStoreError: Error, LocalizedError, Sendable {
    case keychainStatus(Int32)
    case missingCredential(ModelProvider)

    public var errorDescription: String? {
        switch self {
        case .keychainStatus(let status): return "Could not access the macOS Keychain (status \(status))."
        case .missingCredential(.glmCodingPlan): return "No GLM Coding Plan API key is saved in Keychain. Add one in Settings before connecting or running a translation."
        case .missingCredential(.lmStudio): return "No LM Studio credential is saved in Keychain."
        }
    }
}

public struct KeychainCredentialStore: Sendable {
    private let service: String

    public init(service: String = "com.crystalagentictranslator.credentials") {
        self.service = service
    }

    public func credential(for provider: ModelProvider) throws -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychainStatus(status)
        }
        return value
    }

    public func save(_ credential: String, for provider: ModelProvider) throws {
        let data = Data(credential.utf8)
        let query = baseQuery(provider)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychainStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.keychainStatus(updateStatus)
        }
    }

    public func delete(for provider: ModelProvider) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychainStatus(status) }
    }

    @discardableResult
    public func migrateLegacyCredential(in settings: inout AppSettings) throws -> Bool {
        guard !settings.apiToken.isEmpty else { return false }
        if try credential(for: settings.provider)?.isEmpty != false {
            try save(settings.apiToken, for: settings.provider)
        }
        settings.apiToken = ""
        return true
    }

    private func baseQuery(_ provider: ModelProvider) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: provider.rawValue]
    }
}
