import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Security

/// Generic-password items under one service; each account is one secret (e.g. a rewrite endpoint's API key).
@DependencyClient
struct KeychainClient {
	var read: @Sendable (_ account: String) -> String? = { _ in nil }
	/// Nil or empty deletes the item.
	var write: @Sendable (_ account: String, _ value: String?) throws -> Void
}

struct KeychainError: Error, LocalizedError {
	var status: OSStatus
	var errorDescription: String? {
		SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
	}
}

extension KeychainClient: DependencyKey {
	static let service = "com.genovamongalo.LegacyScribe.rewrite"

	static var liveValue: Self {
		func query(_ account: String) -> [String: Any] {
			[
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrAccount as String: account,
			]
		}

		return Self(
			read: { account in
				var item = query(account)
				item[kSecReturnData as String] = true
				item[kSecMatchLimit as String] = kSecMatchLimitOne
				var result: CFTypeRef?
				guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
				      let data = result as? Data
				else { return nil }
				return String(data: data, encoding: .utf8)
			},
			write: { account, value in
				let status = SecItemDelete(query(account) as CFDictionary)
				guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
				guard let value, !value.isEmpty else { return }
				var item = query(account)
				item[kSecValueData as String] = Data(value.utf8)
				item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
				let addStatus = SecItemAdd(item as CFDictionary, nil)
				guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
			}
		)
	}

	static var testValue: Self { Self() }
}

extension DependencyValues {
	var keychain: KeychainClient {
		get { self[KeychainClient.self] }
		set { self[KeychainClient.self] = newValue }
	}
}

extension RewriteEndpointRole {
	/// Keychain account holding this endpoint's API key.
	var keychainAccount: String { "apiKey.\(rawValue)" }
}
