import CryptoKit
import Foundation
import Security

struct DesktopPairing: Codable {
    var deviceID: String
    var tokenAccount: String
    var keyAccount: String
}

actor DesktopRelay {
    private let session: URLSession

    init() {
        session = RelayTransport.makeSession()
    }

    struct PairingRecord: Decodable {
        struct PhoneDevice: Decodable { let id: String? }
        let id: String; let phonePublicKey: String?; let state: String; let deviceToken: String?; let phoneProof: String?
    }

    func pair(code: String, baseURL: URL, device: Device, onFingerprint: @escaping @Sendable (String) async -> Void) async throws -> DesktopPairing {
        let waiting: PairingRecord = try await request(baseURL, "/v1/pairings/\(code)", "GET", Optional<String>.none)
        guard let phonePublicKey = waiting.phonePublicKey else { throw AppServerError.malformed("Invalid phone public key") }
        let privateKey = P256.KeyAgreement.PrivateKey()
        guard let phoneData = Data(base64Encoded: phonePublicKey) else { throw AppServerError.malformed("Invalid phone public key") }
        let phoneKey = try P256.KeyAgreement.PublicKey(x963Representation: phoneData)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: phoneKey)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("CodexAccounts/v1".utf8), sharedInfo: Data(), outputByteCount: 32)
        let fingerprint = key.withUnsafeBytes { Data(SHA256.hash(data: Data($0))).prefix(6) }.map { String(format: "%02X", $0) }.joined(separator: "-")
        await onFingerprint(fingerprint)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data("desktop-claim:\(waiting.id)".utf8), using: key)).base64EncodedString()
        let payload = Claim(desktopPublicKey: privateKey.publicKey.x963Representation.base64EncodedString(), desktopProof: proof, device: device)
        _ = try await request(baseURL, "/v1/pairings/\(code)/claim", "PUT", payload) as PairingRecord
        while true {
            try await Task.sleep(for: .seconds(2))
            let status: PairingRecord = try await request(baseURL, "/v1/pairings/\(waiting.id)/status", "GET", Optional<String>.none, extraHeaders: ["X-Desktop-Proof": proof])
            if status.state == "confirmed", let token = status.deviceToken, let phoneProof = status.phoneProof {
                guard let proofData = Data(base64Encoded: phoneProof), HMAC<SHA256>.isValidAuthenticationCode(proofData, authenticating: Data("phone-confirm:\(waiting.id)".utf8), using: key) else { throw AppServerError.malformed("Invalid iPhone pairing proof") }
                let account = "desktop-key-\(device.id)", tokenAccount = "desktop-token-\(device.id)"
                try MacKeychain.save(key.withUnsafeBytes { Data($0) }, account: account)
                try MacKeychain.save(Data(token.utf8), account: tokenAccount)
                return DesktopPairing(deviceID: device.id, tokenAccount: tokenAccount, keyAccount: account)
            }
        }
    }

    func upload(snapshot: Snapshot, pairing: DesktopPairing, baseURL: URL) async throws {
        guard let keyData = MacKeychain.load(account: pairing.keyAccount), let tokenData = MacKeychain.load(account: pairing.tokenAccount), let token = String(data: tokenData, encoding: .utf8) else { throw AppServerError.malformed("Pairing key is missing") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
        let envelope = Envelope(version: 1, nonce: sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() }, ciphertext: sealed.ciphertext.base64EncodedString(), tag: sealed.tag.base64EncodedString(), observedAt: snapshot.observedAt)
        do {
            let _: Empty = try await request(baseURL, "/v1/devices/\(pairing.deviceID)/snapshot", "PUT", envelope, token: token)
        } catch RelayHTTPError.unauthorized {
            let _: RecoveryResponse = try await request(baseURL, "/v1/devices/\(pairing.deviceID)/recover", "PUT", ["token": token])
            let _: Empty = try await request(baseURL, "/v1/devices/\(pairing.deviceID)/snapshot", "PUT", envelope, token: token)
        }
    }

    func pendingRemoteCommands(pairing: DesktopPairing, baseURL: URL) async throws -> [RemoteCommand] {
        let creds = try credentials(pairing)
        let response: CommandList = try await request(baseURL, "/v1/devices/\(pairing.deviceID)/commands", "GET", Optional<String>.none, token: creds.token)
        return try response.commands.map { try DesktopRelay.openEnvelope($0.envelope, key: creds.key, as: RemoteCommand.self) }
    }

    func remoteCommandStream(pairing: DesktopPairing, baseURL: URL) throws -> AsyncThrowingStream<RemoteCommand, Error> {
        let creds = try credentials(pairing)
        let parsed = try RelayURLPolicy.parse(baseURL.absoluteString)
        guard var components = URLComponents(url: parsed.url, resolvingAgainstBaseURL: true) else { throw AppServerError.rpc("Invalid relay URL") }
        components.scheme = parsed.url.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = "/v1/devices/\(pairing.deviceID)/stream"
        components.queryItems = [URLQueryItem(name: "role", value: "companion")]
        guard let url = components.url else { throw AppServerError.rpc("Invalid relay WebSocket URL") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        let key = creds.key
        return AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            while !Task.isCancelled {
                                let message = try await socket.receive()
                                let data: Data
                                switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                                if let envelope = try? decoder.decode(PushedCommand.self, from: data), envelope.type == "command",
                                   let command = try? DesktopRelay.openEnvelope(envelope.command.envelope, key: key, as: RemoteCommand.self) {
                                    continuation.yield(command)
                                }
                            }
                        }
                        group.addTask {
                            while !Task.isCancelled {
                                try await socket.send(.string("{\"type\":\"heartbeat\"}"))
                                try await Task.sleep(for: .seconds(20))
                            }
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                socket.cancel(with: .goingAway, reason: nil)
            }
            continuation.onTermination = { _ in worker.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    func acknowledgeRemoteCommand(_ id: String, pairing: DesktopPairing, baseURL: URL) async throws {
        let token = try credentials(pairing).token
        let _: Empty = try await request(baseURL, "/v1/devices/\(pairing.deviceID)/commands/\(id)/ack", "POST", Optional<String>.none, token: token)
    }

    func publishRemoteEvent(
        pairing: DesktopPairing,
        baseURL: URL,
        accountFingerprint: String,
        threadId: String,
        items: [RemoteStreamItem],
        capabilities: SessionCapabilities?,
        approval: RemoteApprovalRequest?,
        resolvedApprovalRequestId: String?,
        activeTurnId: String?
    ) async throws {
        let creds = try credentials(pairing)
        let payload = RemoteEventPayload(
            items: items,
            capabilities: capabilities,
            approval: approval,
            resolvedApprovalRequestId: resolvedApprovalRequestId,
            activeTurnId: activeTurnId
        )
        let envelope = try DesktopRelay.sealEnvelope(payload, key: creds.key)
        let body = EncryptedEventBox(accountFingerprint: accountFingerprint, threadId: threadId, envelope: envelope)
        let _: Empty = try await request(baseURL, "/v1/devices/\(pairing.deviceID)/events", "POST", body, token: creds.token)
    }

    nonisolated private static func sealEnvelope<T: Encodable>(_ value: T, key: Data) throws -> Envelope {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let sealed = try AES.GCM.seal(try encoder.encode(value), using: SymmetricKey(data: key))
        return Envelope(
            version: 1,
            nonce: sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            observedAt: Date()
        )
    }

    nonisolated private static func openEnvelope<T: Decodable>(_ envelope: Envelope, key: Data, as: T.Type) throws -> T {
        guard let nonce = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag) else { throw AppServerError.malformed("Invalid remote envelope") }
        let plaintext = try AES.GCM.open(try AES.GCM.SealedBox(nonce: .init(data: nonce), ciphertext: ciphertext, tag: tag), using: SymmetricKey(data: key))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: plaintext)
    }

    private func credentials(_ pairing: DesktopPairing) throws -> (key: Data, token: String) {
        guard let keyData = MacKeychain.load(account: pairing.keyAccount), let tokenData = MacKeychain.load(account: pairing.tokenAccount), let token = String(data: tokenData, encoding: .utf8) else { throw AppServerError.malformed("Pairing key is missing") }
        return (keyData, token)
    }

    private func request<R: Decodable, B: Encodable>(_ base: URL, _ path: String, _ method: String, _ body: B?, token: String? = nil, extraHeaders: [String: String] = [:]) async throws -> R {
        let parsed = try RelayURLPolicy.parse(base.absoluteString)
        guard let url = URL(string: path, relativeTo: parsed.url) else { throw AppServerError.rpc("Invalid relay URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (header, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: header) }
        if let body { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppServerError.rpc("Invalid relay response") }
        if http.statusCode == 401 { throw RelayHTTPError.unauthorized }
        guard 200..<300 ~= http.statusCode else { throw AppServerError.rpc("Relay request failed (\(http.statusCode))") }
        if data.isEmpty, let empty = Empty() as? R { return empty }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(R.self, from: data)
    }
    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch let error as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
            try await Task.sleep(for: .milliseconds(700))
            return try await session.data(for: request)
        }
    }
    private struct Claim: Encodable { let desktopPublicKey, desktopProof: String; let device: Device }
    private struct Envelope: Codable { let version: Int; let nonce, ciphertext, tag: String; let observedAt: Date }
    private struct RecoveryResponse: Decodable { let ok: Bool }
    private struct Empty: Codable {}
    private struct BoxedCommand: Decodable { let id: String; let kind: String; let expiresAt: Date; let envelope: Envelope }
    private struct CommandList: Decodable { let commands: [BoxedCommand] }
    private struct PushedCommand: Decodable { let type: String; let command: BoxedCommand }
    private struct EncryptedEventBox: Encodable {
        let accountFingerprint, threadId: String
        let envelope: Envelope
    }
    private enum RelayHTTPError: Error { case unauthorized }
}

enum MacKeychain {
    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CodexAccountsCompanion", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        SecItemDelete(query as CFDictionary)
        var value = query
        value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw AppServerError.malformed("Unable to save the pairing key") }
    }
    static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CodexAccountsCompanion", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
}
