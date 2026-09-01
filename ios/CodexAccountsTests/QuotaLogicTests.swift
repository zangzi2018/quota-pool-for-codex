import XCTest
@testable import CodexAccounts

final class QuotaLogicTests: XCTestCase {
    func testDefaultAccountNamePoolContainsOneHundredUniqueAliases() {
        XCTAssertEqual(DefaultAccountNames.all.count, 100)
        XCTAssertEqual(Set(DefaultAccountNames.all).count, 100)
    }

    func testCurrentFirstThenPlanThenLongestQuota() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ id: String, _ plan: String, current: Bool, duration: Int?, remaining: Double) -> AccountRowModel {
            let account = Account(id: id, email: "\(id)@example.com", alias: id, planType: plan, renewalAt: nil)
            let presence = AccountPresence(deviceId: "d", accountId: id, isCurrent: current, profileKey: id, lastSeenAt: date)
            let quotas = duration.map { [RateLimitWindow(id: id, accountId: id, durationMins: $0, usedPercent: 100 - remaining, resetsAt: date, observedAt: date)] } ?? []
            return AccountRowModel(account: account, presence: presence, quotas: quotas)
        }
        let result = AccountSorter.sorted([row("plus", "plus", current: false, duration: 10_080, remaining: 99), row("pro-low", "pro", current: false, duration: 10_080, remaining: 20), row("current", "free", current: true, duration: nil, remaining: 0), row("pro-high", "pro", current: false, duration: 10_080, remaining: 80)])
        XCTAssertEqual(result.map(\.id), ["current", "pro-high", "pro-low", "plus"])
    }

    func testNamesAreDurationDriven() {
        let date = Date()
        XCTAssertEqual(RateLimitWindow(id: "a", accountId: "a", durationMins: 300, usedPercent: 1, resetsAt: date, observedAt: date).displayName, "5-hour quota")
        XCTAssertEqual(RateLimitWindow(id: "b", accountId: "a", durationMins: 10_080, usedPercent: 1, resetsAt: date, observedAt: date).displayName, "Weekly quota")
    }

    func testAbsentFiveHourQuotaStaysAbsent() {
        let date = Date()
        let windows = [RateLimitWindow(id: "week", accountId: "research", durationMins: 10_080, usedPercent: 10, resetsAt: date, observedAt: date)]
        XCTAssertFalse(windows.contains { $0.durationMins == 300 })
    }

    func testGenericQuotaNameAndClamping() {
        let date = Date()
        let quota = RateLimitWindow(id: "x", accountId: "a", durationMins: 1_440, usedPercent: 130, resetsAt: date, observedAt: date)
        XCTAssertEqual(quota.displayName, "1-day quota")
        XCTAssertEqual(quota.remainingPercent, 0)
    }

    func testAuthoritativeResetCountCanExceedDetails() {
        let summary = ResetCreditSummary(accountId: "a", availableCount: 3, credits: [ResetCredit(id: "1", accountId: "a", title: nil, resetType: "codexRateLimits", status: "available", grantedAt: .now, expiresAt: nil)])
        XCTAssertTrue(summary.hasPartialDetails)
    }

    func testUsageAccumulatorTreatsFirstCumulativeEventAsReplayBaseline() {
        var accumulator = UsageAccumulator()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let baseline = UsageObservation(deviceId: "mac", deviceName: "Mac", accountFingerprint: "account", threadId: "thread", observedAt: day, cumulative: .init(inputTokens: 100, cachedInputTokens: 25, outputTokens: 30, reasoningTokens: 10, totalTokens: 140))
        XCTAssertEqual(accumulator.observe(baseline), .zero)
        var update = baseline
        update.cumulative = .init(inputTokens: 160, cachedInputTokens: 35, outputTokens: 50, reasoningTokens: 15, totalTokens: 215)
        XCTAssertEqual(accumulator.observe(update), .init(inputTokens: 60, cachedInputTokens: 10, outputTokens: 20, reasoningTokens: 5, totalTokens: 75))
        XCTAssertEqual(accumulator.days.first?.tokens.totalTokens, 75)
    }

    func testUsageAccumulatorDoesNotDoubleCountReplayOrCounterReset() {
        var accumulator = UsageAccumulator()
        let base = UsageObservation(deviceId: "mac", deviceName: "Mac", accountFingerprint: "account", threadId: "thread", observedAt: .now, cumulative: .init(totalTokens: 100))
        _ = accumulator.observe(base)
        XCTAssertEqual(accumulator.observe(base), .zero)
        var reset = base
        reset.cumulative = .init(totalTokens: 10)
        XCTAssertEqual(accumulator.observe(reset), .zero)
        XCTAssertTrue(accumulator.days.isEmpty)
    }

    func testGlobalResetRequiresIndependentDeviceAccountEnvironments() {
        let old = [resetSnapshot(deviceID: "mac", accountID: "a", used: 60, resetAt: 100), resetSnapshot(deviceID: "pc", accountID: "b", used: 40, resetAt: 100)]
        let oneChanged = [resetSnapshot(deviceID: "mac", accountID: "a", used: 0, resetAt: 200), resetSnapshot(deviceID: "pc", accountID: "b", used: 40, resetAt: 100)]
        XCTAssertEqual(GlobalResetDetector.evaluate(previous: old, current: oneChanged, announcement: nil).state, .possibleGlobalReset)
        let bothChanged = [resetSnapshot(deviceID: "mac", accountID: "a", used: 0, resetAt: 200), resetSnapshot(deviceID: "pc", accountID: "b", used: 0, resetAt: 200)]
        XCTAssertEqual(GlobalResetDetector.evaluate(previous: old, current: bothChanged, announcement: nil).state, .confirmed)
    }

    func testTiboAnnouncementDoesNotConfirmResetWithoutObservedQuotaEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let announcement = TiboAnnouncement(id: "a", observedAt: now, sourceName: "provider", summary: "announcement")
        XCTAssertEqual(GlobalResetDetector.evaluate(previous: [], current: [], announcement: announcement, now: now).state, .announcementObserved)
        XCTAssertEqual(GlobalResetDetector.evaluate(previous: [], current: [], announcement: announcement, now: now.addingTimeInterval(120)).state, .waitingConfirmation)
    }

    func testRemoteEventAssemblerDecryptsWithoutRelaySideMerge() {
        let key = SessionKey(deviceId: "mac", accountFingerprint: "account", threadId: "thread")
        let first = RemoteEventPayload(
            items: [.init(id: "a", kind: .user, text: "hello", state: .completed, createdAt: .now)],
            capabilities: .init(readable: true, writable: true, active: true),
            approval: RemoteApprovalRequest(id: "appr", sessionKey: key, kind: .commandExecution, title: "cmd", detail: "ls", createdAt: .now),
            resolvedApprovalRequestId: nil,
            activeTurnId: "turn-1"
        )
        let second = RemoteEventPayload(
            items: [.init(id: "b", kind: .agent, text: "ok", state: .completed, createdAt: .now)],
            capabilities: .init(readable: true, writable: true, active: false),
            approval: nil,
            resolvedApprovalRequestId: "appr",
            activeTurnId: "turn-1"
        )
        let assembled = RemoteEventAssembler.assemble([(1, first), (2, second)])
        XCTAssertEqual(assembled.items.map(\.id), ["a", "b"])
        XCTAssertEqual(assembled.resolvedApprovalRequestId, "appr")
        XCTAssertNil(assembled.approval)
        XCTAssertEqual(assembled.activeTurnId, nil)
        XCTAssertEqual(assembled.cursor, 2)
    }

    private func resetSnapshot(deviceID: String, accountID: String, used: Double, resetAt: TimeInterval) -> Snapshot {
        let observed = Date(timeIntervalSince1970: resetAt)
        return Snapshot(
            device: Device(id: deviceID, name: deviceID, platform: .macOS, osVersion: "", codexVersion: "", onlineState: .online, lastSeenAt: observed),
            accounts: [Account(id: accountID, email: "\(accountID)@example.com", alias: nil, planType: "pro", renewalAt: nil)],
            presences: [AccountPresence(deviceId: deviceID, accountId: accountID, isCurrent: true, profileKey: accountID, lastSeenAt: observed)],
            rateLimitWindows: [RateLimitWindow(id: "\(deviceID):\(accountID)", accountId: accountID, durationMins: 10_080, usedPercent: used, resetsAt: observed, observedAt: observed)],
            resetCreditSummaries: [], activity: [], observedAt: observed
        )
    }
}
