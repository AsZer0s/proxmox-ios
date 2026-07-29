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

/// Minimal Keychain wrapper for storing per-server passwords. Keyed by the
/// server's UUID so removing a server can clean up its secret.
enum KeychainHelper {
    private static let service = "com.aszer0s.proxmoxmanager"

    @discardableResult
    static func savePassword(_ password: String, for serverID: UUID) -> Bool {
        let account = serverID.uuidString
        guard let data = password.data(using: .utf8) else { return false }

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

    @discardableResult
    static func saveCertificateFingerprint(_ fingerprint: String, for serverID: UUID) -> Bool {
        let account = "\(serverID.uuidString).certificate"
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
            kSecAttrAccount as String: "\(serverID.uuidString).certificate",
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

    static func password(for serverID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    @discardableResult
    static func deletePassword(for serverID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
        ]
        let passwordStatus = SecItemDelete(query as CFDictionary)
        let certificateStatus = deleteCertificateFingerprint(for: serverID)
        return (passwordStatus == errSecSuccess || passwordStatus == errSecItemNotFound) && certificateStatus
    }

    @discardableResult
    private static func deleteCertificateFingerprint(for serverID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(serverID.uuidString).certificate",
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
