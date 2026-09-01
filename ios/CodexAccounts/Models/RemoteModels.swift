import Foundation

enum RemoteStreamItemKind: String, Codable, Sendable { case user, agent, status, command, fileChange, plan, error }
enum RemoteStreamItemState: String, Codable, Sendable { case pending, running, completed, failed, interrupted }

struct RemoteStreamItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var kind: RemoteStreamItemKind
    var text: String
    var state: RemoteStreamItemState
    var createdAt: Date
    /// Delta events reuse a stable item id and append text to the existing row.
    /// Optional keeps old cached/transient payloads decodable.
    var append: Bool? = nil
}

enum ApprovalKind: String, Codable, Sendable { case commandExecution, fileChange, permissions }
struct RemoteApprovalRequest: Codable, Identifiable, Hashable, Sendable {
    /// The opaque JSON-RPC request id is preserved end-to-end.
    let id: String
    var sessionKey: SessionKey
    var kind: ApprovalKind
    var title: String
    var detail: String
    var createdAt: Date
}

enum RemoteCommandKind: String, Codable, Sendable { case open, read, start, steer, interrupt, approvalResponse, close }
struct RemoteEventPayload: Codable, Hashable, Sendable {
    let items: [RemoteStreamItem]
    let capabilities: SessionCapabilities?
    let approval: RemoteApprovalRequest?
    let resolvedApprovalRequestId: String?
    let activeTurnId: String?
}
struct RemoteCommand: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var kind: RemoteCommandKind
    var sessionKey: SessionKey
    var expectedTurnId: String?
    var text: String?
    var approvalRequestId: String?
    var approved: Bool?
    var createdAt: Date
    var expiresAt: Date
}
