//
//  DeviceIdentifier.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 11.07.26.
//

import Foundation
import Security

/// A per-install UUID stored in the Keychain, so it survives app
/// reinstalls (unlike `identifierForVendor`, which is regenerated
/// once all apps from the vendor are removed).
enum DeviceIdentifier {
    private static let service = Bundle.main.bundleIdentifier ?? "CDE.Learn2Singg"
    private static let account = "deviceID"

    /// Returns the stored UUID, generating and persisting one on first access.
    static var uuidString: String {
        if let existing = read() { return existing }
        let fresh = UUID().uuidString
        store(fresh)
        return fresh
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func store(_ value: String) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
