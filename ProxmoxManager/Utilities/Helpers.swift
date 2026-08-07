import Foundation
import SwiftUI

// MARK: - Server persistence

/// Loads and saves the list of configured servers to `UserDefaults` as JSON.
///
/// Credentials (passwords) are stored separately in the Keychain via
/// `KeychainHelper`; only non-secret server metadata is persisted here.
enum ServerStore {
    private static let key = "proxmox.servers"

    static func load() -> [ProxmoxServer] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let servers = try? JSONDecoder().decode([ProxmoxServer].self, from: data) else {
            return []
        }
        return servers
    }

    static func save(_ servers: [ProxmoxServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Keychain

/// Minimal Keychain wrapper for storing per-server secrets. Keyed by the
/// server's UUID so removing a server can clean up its secrets.
enum KeychainHelper {
    private static let service = "com.aszer0s.proxmoxmanager"

    private static func account(for serverID: UUID, suffix: String = "") -> String {
        suffix.isEmpty ? serverID.uuidString : "\(serverID.uuidString).\(suffix)"
    }

    @discardableResult
    static func saveGenericSecret(_ secret: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func genericSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes an independently named secret, such as a PBS credential.
    @discardableResult
    static func deleteGenericSecret(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    static func saveSecret(_ secret: String, authMethod: AuthMethod, for serverID: UUID) -> Bool {
        let account = self.account(for: serverID, suffix: authMethod == .token ? "token" : "password")
        guard let data = secret.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func secret(authMethod: AuthMethod, for serverID: UUID) -> String? {
        let account = self.account(for: serverID, suffix: authMethod == .token ? "token" : "password")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveCertificateFingerprint(_ fingerprint: String, for serverID: UUID) -> Bool {
        let account = self.account(for: serverID, suffix: "certificate")
        guard let data = fingerprint.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func certificateFingerprint(for serverID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: self.account(for: serverID, suffix: "certificate"),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func deleteCredentials(for serverID: UUID) -> Bool {
        let accounts = [
            self.account(for: serverID),
            self.account(for: serverID, suffix: "password"),
            self.account(for: serverID, suffix: "token"),
            self.account(for: serverID, suffix: "certificate"),
        ]
        var allOk = true
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                allOk = false
            }
        }
        return allOk
    }
}
