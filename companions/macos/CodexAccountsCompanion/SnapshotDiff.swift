import Foundation

enum SnapshotDiff {
    static func activity(previous: Snapshot?, accounts: [Account], presences: [AccountPresence], windows: [RateLimitWindow], summaries: [ResetCreditSummary], device: Device, now: Date) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.displayName) })
        if let previous {
            let oldCurrent = previous.presences.first(where: \.isCurrent)?.accountId
            let newCurrent = presences.first(where: \.isCurrent)?.accountId
            if oldCurrent != newCurrent, let newCurrent {
                events.append(event(.activeAccountChanged, device, newCurrent, "Current account changed", "\(oldCurrent.flatMap { names[$0] } ?? "Unknown account") → \(names[newCurrent] ?? "Unknown account")", now))
            }
            let oldWindows = Dictionary(uniqueKeysWithValues: previous.rateLimitWindows.map { ($0.id, $0) })
            let newWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            for (id, quota) in newWindows {
                if let old = oldWindows[id], abs(old.usedPercent - quota.usedPercent) >= 0.5 {
                    events.append(event(.quotaChanged, device, quota.accountId, "\(quota.displayName) changed", "Remaining \(Int(old.remainingPercent.rounded()))% → \(Int(quota.remainingPercent.rounded()))%", now))
                } else if oldWindows[id] == nil {
                    events.append(event(.quotaRefreshed, device, quota.accountId, "Quota refreshed", "\(names[quota.accountId] ?? "Account") \(quota.displayName) refreshed", now))
                }
            }
            for (id, quota) in oldWindows where newWindows[id] == nil {
                events.append(event(.quotaReset, device, quota.accountId, "Quota reset", "\(names[quota.accountId] ?? "Account") \(quota.displayName) reset", now))
            }
            let oldCredits = Set(previous.resetCreditSummaries.flatMap { $0.credits ?? [] }.map(\.id))
            let newCredits = summaries.flatMap { $0.credits ?? [] }
            for credit in newCredits where !oldCredits.contains(credit.id) { events.append(event(.resetAdded, device, credit.accountId, "Saved rate-limit reset added", names[credit.accountId] ?? "Accounts", now)) }
            let currentIDs = Set(newCredits.map(\.id))
            for credit in previous.resetCreditSummaries.flatMap({ $0.credits ?? [] }) where !currentIDs.contains(credit.id) { events.append(event(.resetExpired, device, credit.accountId, "Saved rate-limit reset expired", names[credit.accountId] ?? "Accounts", now)) }
        }
        events.append(event(.deviceSynced, device, nil, "Device synced", device.name, now))
        return Array((events + (previous?.activity ?? [])).sorted { $0.occurredAt > $1.occurredAt }.prefix(200))
    }
    private static func event(_ type: ActivityType, _ device: Device, _ accountID: String?, _ title: String, _ detail: String, _ date: Date) -> ActivityEvent {
        ActivityEvent(id: UUID().uuidString, deviceId: device.id, accountId: accountID, type: type, occurredAt: date, payload: ["title": title, "detail": detail])
    }
}

