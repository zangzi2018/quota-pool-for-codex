import Foundation

protocol TiboAnnouncementProvider: Sendable {
    func latestAnnouncement() async throws -> TiboAnnouncement?
}

/// Production-safe default until a reliable authenticated provider is configured.
struct UnavailableTiboAnnouncementProvider: TiboAnnouncementProvider {
    func latestAnnouncement() async throws -> TiboAnnouncement? { nil }
}

struct UsageObservation: Codable, Hashable, Sendable {
    var deviceId: String
    var deviceName: String
    var accountFingerprint: String
    var threadId: String
    var observedAt: Date
    var cumulative: TokenBreakdown

    var key: String { "\(deviceId):\(accountFingerprint):\(threadId)" }
}

struct UsageAccumulator: Codable, Sendable {
    private(set) var latestByThread: [String: UsageObservation] = [:]
    private(set) var days: [DeviceUsageDay] = []

    /// App Server usage events are cumulative and can be replayed after thread resume.
    /// Only a component-wise positive delta is attributed to the host that emitted it.
    mutating func observe(_ observation: UsageObservation, calendar: Calendar = .current) -> TokenBreakdown {
        let previous = latestByThread[observation.key]?.cumulative ?? .zero
        let delta = TokenBreakdown(
            inputTokens: max(0, observation.cumulative.inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, observation.cumulative.cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, observation.cumulative.outputTokens - previous.outputTokens),
            reasoningTokens: max(0, observation.cumulative.reasoningTokens - previous.reasoningTokens),
            totalTokens: max(0, observation.cumulative.totalTokens - previous.totalTokens)
        )
        if latestByThread[observation.key] == nil {
            // The first cumulative value establishes a replay-safe baseline.
            latestByThread[observation.key] = observation
            return .zero
        }
        latestByThread[observation.key] = observation
        guard delta.totalTokens > 0 else { return .zero }
        let date = calendar.startOfDay(for: observation.observedAt)
        if let index = days.firstIndex(where: { $0.deviceId == observation.deviceId && calendar.isDate($0.date, inSameDayAs: date) }) {
            days[index].tokens = days[index].tokens + delta
        } else {
            days.append(DeviceUsageDay(date: date, deviceId: observation.deviceId, deviceName: observation.deviceName, tokens: delta))
        }
        return delta
    }
}

enum UsageIntensity {
    /// Quantile bands keep a single spike from making the remaining year unreadable.
    static func level(for value: Int64, among values: [Int64]) -> Int {
        guard value > 0 else { return 0 }
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return 0 }
        let rank = positive.partitioningIndex { $0 >= value }
        let percentile = Double(rank + 1) / Double(positive.count)
        switch percentile {
        case ..<0.25: return 1
        case ..<0.50: return 2
        case ..<0.75: return 3
        default: return 4
        }
    }
}

enum GlobalResetDetector {
    struct EnvironmentEvidence: Identifiable, Hashable, Sendable {
        var id: String
        var deviceName: String
        var onlineState: OnlineState
        var previousRemaining: Double?
        var currentRemaining: Double?
        var resetObserved: Bool
    }
    struct Result: Hashable, Sendable {
        var state: TiboEvidenceState
        var changedEnvironmentCount: Int
        var eligibleEnvironmentCount: Int
        var environments: [EnvironmentEvidence]
    }

    static func evaluate(previous: [Snapshot], current: [Snapshot], announcement: TiboAnnouncement?, now: Date = .now) -> Result {
        let oldByEnvironment = environmentQuotas(previous)
        let newByEnvironment = environmentQuotas(current)
        var changed = 0
        var evidence: [EnvironmentEvidence] = []
        for (key, newWindows) in newByEnvironment {
            let oldWindows = oldByEnvironment[key] ?? []
            let reset = newWindows.contains { new in
                guard let old = oldWindows.first(where: { $0.durationMins == new.durationMins }) else { return false }
                return old.usedPercent >= 20 && new.usedPercent <= 1 && new.resetsAt > old.resetsAt
            }
            if reset { changed += 1 }
            let snapshot = current.first { snapshot in snapshot.presences.contains { $0.isCurrent && "\(snapshot.device.id):\($0.accountId)" == key } }
            let preferred = newWindows.first(where: { $0.durationMins == 10_080 }) ?? newWindows.max(by: { $0.durationMins < $1.durationMins })
            let oldPreferred = preferred.flatMap { target in oldWindows.first(where: { $0.durationMins == target.durationMins }) }
            evidence.append(.init(id: key, deviceName: snapshot?.device.name ?? key, onlineState: snapshot?.device.onlineState ?? .offline, previousRemaining: oldPreferred?.remainingPercent, currentRemaining: preferred?.remainingPercent, resetObserved: reset))
        }
        let eligible = newByEnvironment.count
        let state: TiboEvidenceState
        if changed >= 2 { state = .confirmed }
        else if changed == 1, eligible >= 2 { state = .possibleGlobalReset }
        else if let announcement, let expected = announcement.expectedResetAt, expected > now { state = .resetExpected }
        else if let announcement, now.timeIntervalSince(announcement.observedAt) < 60 { state = .announcementObserved }
        else if announcement != nil { state = .waitingConfirmation }
        else { state = .none }
        return .init(state: state, changedEnvironmentCount: changed, eligibleEnvironmentCount: eligible, environments: evidence.sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending })
    }

    private static func environmentQuotas(_ snapshots: [Snapshot]) -> [String: [RateLimitWindow]] {
        var result: [String: [RateLimitWindow]] = [:]
        for snapshot in snapshots {
            for presence in snapshot.presences where presence.isCurrent {
                result["\(snapshot.device.id):\(presence.accountId)"] = snapshot.rateLimitWindows.filter { $0.accountId == presence.accountId }
            }
        }
        return result
    }
}

private extension Array where Element: Comparable {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
