import Foundation

enum Platform: String, Codable, Sendable { case macOS, windows, linux }
enum OnlineState: String, Codable, Sendable { case online, offline, stale, syncFailed, authExpired }

struct SessionKey: Codable, Hashable, Sendable {
    let deviceId: String
    let accountFingerprint: String
    let threadId: String
}

enum ThreadRuntimeState: String, Codable, Sendable {
    case notLoaded, idle, active, systemError, unavailable, readOnly
}

struct SessionCapabilities: Codable, Hashable, Sendable {
    var readable = true
    var resumable = false
    var writable = false
    var active = false
    var steerable = false
    var interruptible = false
    var approvalCapable = false

    static let readOnly = SessionCapabilities()
}

struct SessionSummary: Codable, Identifiable, Hashable, Sendable {
    var key: SessionKey
    var title: String
    var preview: String
    var deviceName: String
    var accountAlias: String
    var planType: String
    var runtimeState: ThreadRuntimeState
    var model: String?
    var reasoningEffort: String?
    var activeTurnId: String?
    var updatedAt: Date
    var capabilities: SessionCapabilities
    var id: String { "\(key.deviceId):\(key.accountFingerprint):\(key.threadId)" }
}

struct TokenBreakdown: Codable, Hashable, Sendable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningTokens: Int64 = 0
    var totalTokens: Int64 = 0

    static let zero = TokenBreakdown()
    static func + (lhs: Self, rhs: Self) -> Self {
        .init(inputTokens: lhs.inputTokens + rhs.inputTokens,
              cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
              outputTokens: lhs.outputTokens + rhs.outputTokens,
              reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
              totalTokens: lhs.totalTokens + rhs.totalTokens)
    }
}

struct DeviceUsageDay: Codable, Identifiable, Hashable, Sendable {
    var date: Date
    var deviceId: String
    var deviceName: String
    var tokens: TokenBreakdown
    var id: String { "\(deviceId):\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)" }
}

enum TiboEvidenceState: String, Codable, Sendable {
    case none, announcementObserved, resetExpected, waitingConfirmation, possibleGlobalReset, confirmed
}

struct TiboAnnouncement: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var observedAt: Date
    var sourceName: String
    var summary: String
    var expectedResetAt: Date? = nil
}

struct Device: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var platform: Platform
    var osVersion: String
    var codexVersion: String
    var onlineState: OnlineState
    var lastSeenAt: Date
}

struct Account: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var email: String
    var alias: String?
    var planType: String
    var renewalAt: Date?
    var displayName: String { alias?.isEmpty == false ? alias! : email }
}

struct AccountPresence: Codable, Hashable, Sendable {
    let deviceId: String
    let accountId: String
    var isCurrent: Bool
    var profileKey: String
    var lastSeenAt: Date
}

struct RateLimitWindow: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let accountId: String
    var limitId: String?
    var durationMins: Int
    var usedPercent: Double
    var resetsAt: Date
    var observedAt: Date
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    var displayName: String {
        switch durationMins {
        case 300: "5-hour quota"
        case 10_080: "Weekly quota"
        default: "\(QuotaFormatter.genericDuration(durationMins)) quota"
        }
    }
}

struct ResetCredit: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let accountId: String
    var title: String?
    var resetType: String
    var status: String
    var grantedAt: Date
    var expiresAt: Date?
}

struct ResetCreditSummary: Codable, Hashable, Sendable {
    let accountId: String
    var availableCount: Int
    var credits: [ResetCredit]?
    var hasPartialDetails: Bool { credits.map { availableCount > $0.count } ?? (availableCount > 0) }
}

enum GlobalResetSource: String, Codable, Sendable { case official, manual, observed }
struct GlobalRateLimitReset: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var occurredAt: Date
    var source: GlobalResetSource
    var note: String?
}

enum ActivityType: String, Codable, Sendable {
    case activeAccountChanged, quotaChanged, quotaRefreshed, quotaReset
    case resetAdded, resetExpired, deviceSynced, deviceOffline
}

struct ActivityEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let deviceId: String
    var accountId: String?
    var type: ActivityType
    var occurredAt: Date
    var payload: [String: String]
}

struct Snapshot: Codable, Sendable {
    var schemaVersion: Int = 1
    var device: Device
    var accounts: [Account]
    var presences: [AccountPresence]
    var rateLimitWindows: [RateLimitWindow]
    var resetCreditSummaries: [ResetCreditSummary]
    var globalRateLimitResets: [GlobalRateLimitReset] = []
    var activity: [ActivityEvent]
    var observedAt: Date
    /// v1.1 additions are optional so existing encrypted Snapshot v1 caches remain decodable.
    var sessionSummaries: [SessionSummary]? = nil
    var deviceUsageDays: [DeviceUsageDay]? = nil
    var tiboAnnouncement: TiboAnnouncement? = nil
}

struct AccountRowModel: Identifiable, Hashable {
    let account: Account
    let presence: AccountPresence
    let quotas: [RateLimitWindow]
    var id: String { account.id }
    var isCurrent: Bool { presence.isCurrent }
    var longestQuota: RateLimitWindow? { quotas.filter { $0.durationMins > 0 && $0.usedPercent.isFinite }.max { $0.durationMins < $1.durationMins } }
}
