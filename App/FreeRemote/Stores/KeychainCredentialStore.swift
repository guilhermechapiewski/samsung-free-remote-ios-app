import Foundation
import os
import SamsungTVKit
import Security

/// Persists each TV's pairing credentials as a JSON-encoded generic-password keychain item
/// (account = the TV's id), readable after first unlock and never synced or migrated off-device.
struct KeychainCredentialStore: CredentialStore {
    struct KeychainError: Error, Equatable {
        let status: OSStatus
    }

    private static let logger = Logger(subsystem: "FreeRemote", category: "KeychainCredentialStore")

    let service: String

    init(service: String = "FreeRemote.credentials") {
        self.service = service
    }

    func load(_ id: TVID) -> TVCredentials? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Self.logger.error("Keychain read failed: \(status, privacy: .public)")
            }
            return nil
        }
        do {
            return try JSONDecoder().decode(TVCredentials.self, from: data)
        } catch {
            Self.logger.error("Stored credentials are unreadable; ignoring them")
            return nil
        }
    }

    func save(_ c: TVCredentials, for id: TVID) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(c),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = baseQuery(for: id)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Self.logger.error("Keychain write failed: \(status, privacy: .public)")
            throw KeychainError(status: status)
        }
    }

    func delete(_ id: TVID) {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error("Keychain delete failed: \(status, privacy: .public)")
        }
    }

    private func baseQuery(for id: TVID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.rawValue,
        ]
    }
}
