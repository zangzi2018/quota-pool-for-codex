import Foundation

enum QuotaFormatter {
    static func genericDuration(_ minutes: Int) -> String {
        if minutes % 10_080 == 0 { return minutes == 10_080 ? "Weekly" : "\(minutes / 10_080)-week" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))% remaining" }
    static func resetDescription(_ date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds > 0, seconds < 24 * 3600 {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(max(1, minutes))m"
        }
        return date.formatted(.dateTime.weekday(.wide).hour().minute()) + " reset"
    }
}

enum AccountSorter {
    static func sorted(_ rows: [AccountRowModel]) -> [AccountRowModel] {
        rows.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            let lp = planRank(lhs.account.planType), rp = planRank(rhs.account.planType)
            if lp != rp { return lp > rp }
            switch (lhs.longestQuota, rhs.longestQuota) {
            case let (l?, r?):
                if l.remainingPercent != r.remainingPercent { return l.remainingPercent > r.remainingPercent }
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return lhs.account.displayName.localizedStandardCompare(rhs.account.displayName) == .orderedAscending
        }
    }

    static func planRank(_ plan: String) -> Int {
        switch plan.lowercased() { case "pro": 300; case "plus": 200; case "free": 100; default: 0 }
    }
}

struct RawRateLimitBucket: Decodable {
    struct RawWindow: Decodable { let usedPercent: Double; let windowDurationMins: Int; let resetsAt: TimeInterval }
    let limitId: String?
    let limitName: String?
    let primary: RawWindow?
    let secondary: RawWindow?
}

enum RateLimitNormalizer {
    static func normalize(_ buckets: [RawRateLimitBucket], accountId: String, observedAt: Date) -> [RateLimitWindow] {
        buckets.flatMap { bucket in
            [bucket.primary, bucket.secondary].compactMap { raw in
                raw.map {
                    RateLimitWindow(
                        id: "\(accountId):\(bucket.limitId ?? "default"):\($0.windowDurationMins)", accountId: accountId,
                        limitId: bucket.limitId, durationMins: $0.windowDurationMins, usedPercent: $0.usedPercent,
                        resetsAt: Date(timeIntervalSince1970: $0.resetsAt), observedAt: observedAt
                    )
                }
            }
        }
    }
}

