import CryptoKit
import Foundation
import Security

/// Long-term device identity (Ed25519) kept in the Keychain.
struct DeviceIdentity: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKeyRaw: Data { privateKey.publicKey.rawRepresentation }
    var publicKeyB64: String { publicKeyRaw.base64EncodedString() }
    var deviceId: String { OPACrypto.id(ofPublicKey: publicKeyRaw) }

    func sign(_ message: Data) throws -> Data { try privateKey.signature(for: message) }
}

enum Keychain {
    static let service = "com.openpersonalagent.identity"

    static func read(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

enum IdentityStore {
    private static let account = "device.ed25519"

    /// Loads the identity, creating and persisting one on first use.
    static func loadOrCreate() -> DeviceIdentity {
        if let raw = Keychain.read(account), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return DeviceIdentity(privateKey: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        Keychain.write(key.rawRepresentation, account: account)
        return DeviceIdentity(privateKey: key)
    }

    static func reset() { Keychain.delete(account) }
}
