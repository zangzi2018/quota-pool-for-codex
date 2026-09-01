import CryptoKit
import Foundation
import UIKit

enum RelayError: LocalizedError {
    case invalidURL, invalidResponse, server(String)
    var errorDescription: String? { switch self { case .invalidURL: "Invalid relay URL"; case .invalidResponse: "Invalid relay response"; case .server(let message): message } }
}

struct PairingStart: Decodable { let sessionId: String; let code: String; let expiresAt: Date }
struct PairingStatus: Decodable {
    struct RemoteDevice: Decodable { let id: String; let name: String; let platform: String?; let osVersion: String? }
    let id: String
    let state: String
    let expiresAt: Date
    let desktopPublicKey: String?
    let desktopProof: String?
    let device: RemoteDevice?
    let deviceToken: String?
}
struct PairingSession {
    let start: PairingStart
    let privateKey: P256.KeyAgreement.PrivateKey
    let pairingAuth: String
}

struct DeviceConnection: Codable, Identifiable {
    let id: String
    let name: String
    let tokenAccount: String
    let keyAccount: String
}
struct RelayPresence: Codable { let state: OnlineState; let lastSeen: Date? }

actor RelayClient {
    private let session: URLSession
    init(session: URLSession = RelayTransport.makeSession()) { self.session = session }

    func createPairing(baseURL: URL) async throws -> PairingSession {
        let privateKey = CryptoBox.keyPair()
        let pairingAuth = CryptoBox.randomAuth()
        let phoneName = await MainActor.run { UIDevice.current.name }
        let requestBody = ["phonePublicKey": CryptoBox.publicKey(privateKey), "phoneName": String(phoneName.prefix(128)), "authHash": CryptoBox.sha256Base64(pairingAuth)]
        let start: PairingStart = try await request(baseURL: baseURL, path: "/v1/pairings", method: "POST", body: requestBody)
        return PairingSession(start: start, privateKey: privateKey, pairingAuth: pairingAuth)
    }

    func status(baseURL: URL, sessionId: String, pairingAuth: String) async throws -> PairingStatus {
        try await request(baseURL: baseURL, path: "/v1/pairings/\(sessionId)/status", method: "GET", body: Optional<String>.none, extraHeaders: ["X-Pairing-Auth": pairingAuth])
    }

    func confirm(baseURL: URL, session: PairingSession, status: PairingStatus) async throws -> DeviceConnection {
        guard let publicKey = status.desktopPublicKey, let desktopProof = status.desktopProof, let device = status.device else { throw RelayError.invalidResponse }
        let key = try CryptoBox.sharedKey(privateKey: session.privateKey, peerPublicKey: publicKey)
        guard CryptoBox.verify(desktopProof, key: key, message: "desktop-claim:\(session.start.sessionId)") else { throw CryptoBoxError.invalidProof }
        let proof = CryptoBox.proof(key: key, message: "phone-confirm:\(session.start.sessionId)")
        let confirmed: PairingStatus = try await request(baseURL: baseURL, path: "/v1/pairings/\(session.start.sessionId)/confirm", method: "PUT", body: ["phoneProof": proof], extraHeaders: ["X-Pairing-Auth": session.pairingAuth])
        guard let token = confirmed.deviceToken else { throw RelayError.invalidResponse }
        let keyData = key.withUnsafeBytes { Data($0) }
        let account = "device-key-\(device.id)"
        let tokenAccount = "device-token-\(device.id)"
        try KeychainStore.save(keyData, account: account)
        try KeychainStore.save(Data(token.utf8), account: tokenAccount)
        return DeviceConnection(id: device.id, name: device.name, tokenAccount: tokenAccount, keyAccount: account)
    }

    func snapshot(baseURL: URL, connection: DeviceConnection) async throws -> Snapshot {
        guard let tokenData = KeychainStore.load(account: connection.tokenAccount), let token = String(data: tokenData, encoding: .utf8), let keyData = KeychainStore.load(account: connection.keyAccount) else { throw CryptoBoxError.missingKey }
        let envelope: EncryptedEnvelope = try await request(baseURL: baseURL, path: "/v1/devices/\(connection.id)/snapshot", method: "GET", body: Optional<String>.none, token: token)
        return try CryptoBox.decrypt(envelope, key: SymmetricKey(data: keyData), as: Snapshot.self)
    }

    func presence(baseURL: URL, connection: DeviceConnection) async throws -> RelayPresence {
        let token = try deviceToken(connection)
        return try await request(baseURL: baseURL, path: "/v1/devices/\(connection.id)/presence", method: "GET", body: Optional<String>.none, token: token)
    }

    func sendRemote(baseURL: URL, connection: DeviceConnection, command: RemoteCommand) async throws {
        let token = try deviceToken(connection)
        let key = try deviceKey(connection)
        let envelope = try CryptoBox.encrypt(command, key: key, observedAt: command.createdAt)
        let body = EncryptedCommandBox(id: command.id, kind: command.kind, expiresAt: command.expiresAt, envelope: envelope)
        let _: EmptyResponse = try await request(baseURL: baseURL, path: "/v1/devices/\(connection.id)/commands", method: "POST", body: body, token: token)
    }

    func remoteEvents(baseURL: URL, connection: DeviceConnection, session: SessionKey, after: Int = 0) async throws -> RemoteEventsResponse {
        let token = try deviceToken(connection)
        let key = try deviceKey(connection)
        let query = "accountFingerprint=\(session.accountFingerprint.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.accountFingerprint)&threadId=\(session.threadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.threadId)&after=\(after)"
        let boxed: EncryptedEventsResponse = try await request(baseURL: baseURL, path: "/v1/devices/\(connection.id)/events?\(query)", method: "GET", body: Optional<String>.none, token: token)
        let payloads = try boxed.events.map { event in
            (event.sequence, try CryptoBox.decrypt(event.envelope, key: key, as: RemoteEventPayload.self))
        }
        return RemoteEventAssembler.assemble(payloads)
    }

    func remoteEventStream(baseURL: URL, connection: DeviceConnection, sessionKey: SessionKey) throws -> AsyncThrowingStream<RemoteEventsResponse, Error> {
        let token = try deviceToken(connection)
        let key = try deviceKey(connection)
        let parsed = try RelayURLPolicy.parse(baseURL.absoluteString)
        guard var components = URLComponents(url: parsed.url, resolvingAgainstBaseURL: true) else { throw RelayError.invalidURL }
        components.scheme = parsed.url.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = "/v1/devices/\(connection.id)/stream"
        components.queryItems = [URLQueryItem(name: "role", value: "controller")]
        guard let url = components.url else { throw RelayError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        return AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        guard let envelope = try? JSONDecoder.codex.decode(PushedEvent.self, from: data),
                              envelope.type == "event",
                              envelope.event.accountFingerprint == sessionKey.accountFingerprint,
                              envelope.event.threadId == sessionKey.threadId,
                              let payload = try? CryptoBox.decrypt(envelope.event.envelope, key: key, as: RemoteEventPayload.self) else { continue }
                        continuation.yield(RemoteEventAssembler.assemble([(envelope.event.sequence, payload)]))
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
                socket.cancel(with: .goingAway, reason: nil)
            }
            continuation.onTermination = { _ in worker.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    private func deviceToken(_ connection: DeviceConnection) throws -> String {
        guard let tokenData = KeychainStore.load(account: connection.tokenAccount), let token = String(data: tokenData, encoding: .utf8) else { throw CryptoBoxError.missingKey }
        return token
    }

    private func deviceKey(_ connection: DeviceConnection) throws -> SymmetricKey {
        guard let keyData = KeychainStore.load(account: connection.keyAccount) else { throw CryptoBoxError.missingKey }
        return SymmetricKey(data: keyData)
    }

    private func request<Response: Decodable, Body: Encodable>(baseURL: URL, path: String, method: String, body: Body?, token: String? = nil, extraHeaders: [String: String] = [:]) async throws -> Response {
        let parsed = try RelayURLPolicy.parse(baseURL.absoluteString)
        guard let url = URL(string: path, relativeTo: parsed.url) else { throw RelayError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (header, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: header) }
        if let body { request.httpBody = try JSONEncoder.codex.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data)["error"]) ?? "Relay error \(http.statusCode)"
            throw RelayError.server(message)
        }
        return try JSONDecoder.codex.decode(Response.self, from: data)
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch let error as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
            try await Task.sleep(for: .milliseconds(700))
            return try await session.data(for: request)
        }
    }
}

private struct EmptyResponse: Codable {}
private struct EncryptedCommandBox: Encodable {
    let id: String
    let kind: RemoteCommandKind
    let expiresAt: Date
    let envelope: EncryptedEnvelope
}
private struct EncryptedEventsResponse: Decodable {
    let events: [EncryptedEventBox]
    let cursor: Int
}
private struct EncryptedEventBox: Decodable {
    let sequence: Int
    let accountFingerprint: String
    let threadId: String
    let envelope: EncryptedEnvelope
}
struct RemoteEventsResponse: Codable {
    let items: [RemoteStreamItem]
    let capabilities: SessionCapabilities?
    let approval: RemoteApprovalRequest?
    let resolvedApprovalRequestId: String?
    let activeTurnId: String?
    let cursor: Int
}
enum RemoteEventAssembler {
    static func assemble(_ events: [(Int, RemoteEventPayload)]) -> RemoteEventsResponse {
        var items: [RemoteStreamItem] = []
        var capabilities: SessionCapabilities?
        var approval: RemoteApprovalRequest?
        var resolvedApprovalRequestId: String?
        var activeTurnId: String?
        var cursor = 0
        for (sequence, payload) in events.sorted(by: { $0.0 < $1.0 }) {
            items.append(contentsOf: payload.items)
            if let value = payload.capabilities { capabilities = value }
            if let value = payload.approval { approval = value }
            if let value = payload.resolvedApprovalRequestId {
                resolvedApprovalRequestId = value
                if approval?.id == value { approval = nil }
            }
            if payload.capabilities?.active == false { activeTurnId = nil }
            else if let value = payload.activeTurnId { activeTurnId = value }
            cursor = sequence
        }
        return .init(items: items, capabilities: capabilities, approval: approval, resolvedApprovalRequestId: resolvedApprovalRequestId, activeTurnId: activeTurnId, cursor: cursor)
    }
}
private struct PushedEvent: Decodable {
    struct Event: Decodable {
        let accountFingerprint: String
        let threadId: String
        let envelope: EncryptedEnvelope
        let sequence: Int
    }
    let type: String
    let event: Event
}
