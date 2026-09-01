import CryptoKit
import Foundation
import Security

enum CryptoBoxError: Error { case malformedEnvelope, missingKey, invalidProof }

struct EncryptedEnvelope: Codable, Sendable {
    let version: Int
    let nonce: String
    let ciphertext: String
    let tag: String
    let observedAt: Date
}

enum CryptoBox {
    static func keyPair() -> P256.KeyAgreement.PrivateKey { .init() }
    static func publicKey(_ privateKey: P256.KeyAgreement.PrivateKey) -> String {
        privateKey.publicKey.x963Representation.base64EncodedString()
    }
    static func sharedKey(privateKey: P256.KeyAgreement.PrivateKey, peerPublicKey: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: peerPublicKey) else { throw CryptoBoxError.malformedEnvelope }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: data)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("CodexAccounts/v1".utf8), sharedInfo: Data(), outputByteCount: 32)
    }
    static func proof(key: SymmetricKey, message: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)).base64EncodedString()
    }
    static func verify(_ proof: String, key: SymmetricKey, message: String) -> Bool {
        guard let data = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(data, authenticating: Data(message.utf8), using: key)
    }
    static func fingerprint(_ key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { Data(SHA256.hash(data: Data($0))).prefix(6) }
        return digest.map { String(format: "%02X", $0) }.joined(separator: "-")
    }
    static func randomAuth() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func sha256Base64(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }
    static func encrypt<T: Encodable>(_ value: T, key: SymmetricKey, observedAt: Date) throws -> EncryptedEnvelope {
        let plaintext = try JSONEncoder.codex.encode(value)
        let box = try AES.GCM.seal(plaintext, using: key)
        return EncryptedEnvelope(version: 1, nonce: box.nonce.withUnsafeBytes { Data($0).base64EncodedString() }, ciphertext: box.ciphertext.base64EncodedString(), tag: box.tag.base64EncodedString(), observedAt: observedAt)
    }
    static func decrypt<T: Decodable>(_ envelope: EncryptedEnvelope, key: SymmetricKey, as: T.Type) throws -> T {
        guard let nonce = Data(base64Encoded: envelope.nonce), let ciphertext = Data(base64Encoded: envelope.ciphertext), let tag = Data(base64Encoded: envelope.tag) else { throw CryptoBoxError.malformedEnvelope }
        let sealed = try AES.GCM.SealedBox(nonce: .init(data: nonce), ciphertext: ciphertext, tag: tag)
        return try JSONDecoder.codex.decode(T.self, from: AES.GCM.open(sealed, using: key))
    }
}

enum KeychainStore {
    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CodexAccounts", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        SecItemDelete(query as CFDictionary)
        var value = query
        value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw CryptoBoxError.missingKey }
    }
    static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CodexAccounts", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
}

extension JSONEncoder {
    static var codex: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]; return value }
}
extension JSONDecoder {
    static var codex: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
