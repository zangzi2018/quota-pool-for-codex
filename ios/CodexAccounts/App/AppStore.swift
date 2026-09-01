import Foundation
import Observation

@MainActor @Observable
final class AppStore {
    var snapshots: [Snapshot] = []
    var selectedDeviceID: String?
    var isSyncing = false
    var errorMessage: String?
    var relayURLString = UserDefaults.standard.string(forKey: "relayURL") ?? "http://127.0.0.1:8787"
    var connections: [DeviceConnection] = []
    var relayConnected = false
    private var previousSnapshotsForResetDetection: [Snapshot] = []
    private let relay = RelayClient()
    private let tiboProvider: any TiboAnnouncementProvider = UnavailableTiboAnnouncementProvider()
    private var isVisualQA: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-qaScreen") || ProcessInfo.processInfo.environment["QUOTA_POOL_VISUAL_QA"] == "1"
        #else
        false
        #endif
    }

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-relayURL"), arguments.indices.contains(flag + 1) {
            relayURLString = arguments[flag + 1]
            UserDefaults.standard.set(relayURLString, forKey: "relayURL")
        }
    }

    var devices: [Device] { snapshots.map(\.device).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var selectedSnapshot: Snapshot? { snapshots.first { $0.device.id == selectedDeviceID } ?? snapshots.first }
    var selectedDevice: Device? { selectedSnapshot?.device }
    var sessionSummaries: [SessionSummary] {
        snapshots.flatMap { $0.sessionSummaries ?? [] }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var deviceUsageDays: [DeviceUsageDay] {
        let rows = snapshots.flatMap { $0.deviceUsageDays ?? [] }
        return Dictionary(grouping: rows, by: \.id).values.compactMap { values in
            guard let first = values.first else { return nil }
            return DeviceUsageDay(date: first.date, deviceId: first.deviceId, deviceName: first.deviceName, tokens: values.map(\.tokens).reduce(.zero, +))
        }.sorted { $0.date < $1.date }
    }
    var resetEvidence: GlobalResetDetector.Result {
        GlobalResetDetector.evaluate(previous: previousSnapshotsForResetDetection, current: snapshots, announcement: snapshots.compactMap(\.tiboAnnouncement).max(by: { $0.observedAt < $1.observedAt }))
    }
    var rows: [AccountRowModel] {
        guard let value = selectedSnapshot else { return [] }
        let presences = Dictionary(grouping: value.presences, by: \.accountId).compactMap { _, items in
            items.sorted { lhs, rhs in lhs.isCurrent != rhs.isCurrent ? lhs.isCurrent : lhs.lastSeenAt > rhs.lastSeenAt }.first
        }
        let rows = presences.compactMap { presence -> AccountRowModel? in
            guard let account = value.accounts.first(where: { $0.id == presence.accountId }) else { return nil }
            let quotas = Array(Dictionary(grouping: value.rateLimitWindows.filter { $0.accountId == account.id }, by: \.id).values.compactMap { $0.max(by: { $0.observedAt < $1.observedAt }) })
            return AccountRowModel(account: account, presence: presence, quotas: quotas)
        }
        return AccountSorter.sorted(rows)
    }
    var resetSummaries: [ResetCreditSummary] {
        let groups = Dictionary(grouping: selectedSnapshot?.resetCreditSummaries ?? [], by: \.accountId)
        return groups.map { accountID, values in
            let count = values.map(\.availableCount).max() ?? 0
            let returned = values.flatMap { $0.credits ?? [] }
            let credits = returned.isEmpty && values.allSatisfy { $0.credits == nil } ? nil : Array(Dictionary(grouping: returned, by: \.id).values.compactMap { $0.first })
            return ResetCreditSummary(accountId: accountID, availableCount: count, credits: credits)
        }
    }

    func bootstrap() async {
        if isVisualQA {
            connections = []
            snapshots = []
            relayConnected = false
            selectedDeviceID = nil
            return
        }
        connections = loadConnections()
        if connections.isEmpty {
            snapshots = []
            relayConnected = false
            UserDefaults.standard.removeObject(forKey: "snapshotCache")
        } else {
            persistRelayURL()
            snapshots = loadSnapshotCache()
            await sync()
        }
        applyLocalOverrides()
        applyHealthStates()
        selectedDeviceID = selectedDeviceID ?? snapshots.first?.device.id
        if !isVisualQA { await NotificationService.reschedule(snapshot: selectedSnapshot) }
        await refreshTiboAnnouncement()
    }

    func runForegroundRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { await sync() }
        }
    }

    private func relayBaseURL() throws -> URL { try RelayURLPolicy.parse(relayURLString).url }

    func sync() async {
        let baseURL: URL
        do { baseURL = try relayBaseURL() } catch { errorMessage = error.localizedDescription; return }
        isSyncing = true; defer { isSyncing = false }
        var values: [Snapshot] = []
        var hadSuccessfulRequest = false
        for connection in connections {
            do {
                var snapshot = try await relay.snapshot(baseURL: baseURL, connection: connection)
                if let presence = try? await relay.presence(baseURL: baseURL, connection: connection) {
                    snapshot.device.onlineState = presence.state
                    if let lastSeen = presence.lastSeen { snapshot.device.lastSeenAt = lastSeen }
                }
                values.append(snapshot); hadSuccessfulRequest = true
            }
            catch { errorMessage = "\(connection.name)：\(error.localizedDescription)" }
        }
        relayConnected = hadSuccessfulRequest
        if !values.isEmpty { previousSnapshotsForResetDetection = snapshots; snapshots = values; applyLocalOverrides(); applyHealthStates(); saveSnapshotCache(); if !isVisualQA { await NotificationService.reschedule(snapshot: selectedSnapshot) } }
        else { applyHealthStates() }
    }

    func persistRelayURL() {
        do {
            let parsed = try RelayURLPolicy.parse(relayURLString)
            relayURLString = parsed.url.absoluteString
            UserDefaults.standard.set(relayURLString, forKey: "relayURL")
            let host = parsed.url.host?.lowercased() ?? ""
            errorMessage = parsed.usesCleartext && host != "127.0.0.1" && host != "localhost" && host != "::1"
                ? "Using a LAN cleartext relay. Use HTTPS on the public internet. Snapshots stay end-to-end encrypted."
                : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func addConnection(_ value: DeviceConnection) {
        let hadNoDevices = connections.isEmpty
        connections.removeAll { $0.id == value.id }; connections.append(value)
        if hadNoDevices {
            snapshots = []
            selectedDeviceID = nil
        }
        if let data = try? JSONEncoder.codex.encode(connections) { UserDefaults.standard.set(data, forKey: "deviceConnections") }
    }
    func updateAlias(accountID: String, alias: String) {
        var values = UserDefaults.standard.dictionary(forKey: "aliasOverrides") as? [String: String] ?? [:]
        values[accountID] = alias; UserDefaults.standard.set(values, forKey: "aliasOverrides")
        applyLocalOverrides()
    }
    func updateRenewal(accountID: String, date: Date?) {
        var values = UserDefaults.standard.dictionary(forKey: "renewalOverrides") as? [String: Double] ?? [:]
        values[accountID] = date?.timeIntervalSince1970 ?? -1; UserDefaults.standard.set(values, forKey: "renewalOverrides")
        applyLocalOverrides()
    }
    private func applyLocalOverrides() {
        let aliases = UserDefaults.standard.dictionary(forKey: "aliasOverrides") as? [String: String] ?? [:]
        let renewals = UserDefaults.standard.dictionary(forKey: "renewalOverrides") as? [String: Double] ?? [:]
        DefaultAccountNames.apply(to: &snapshots)
        for snapshotIndex in snapshots.indices {
            for accountIndex in snapshots[snapshotIndex].accounts.indices {
                let id = snapshots[snapshotIndex].accounts[accountIndex].id
                if let alias = aliases[id] { snapshots[snapshotIndex].accounts[accountIndex].alias = alias }
                if let timestamp = renewals[id] { snapshots[snapshotIndex].accounts[accountIndex].renewalAt = timestamp < 0 ? nil : Date(timeIntervalSince1970: timestamp) }
            }
        }
    }
    private func loadConnections() -> [DeviceConnection] {
        guard let data = UserDefaults.standard.data(forKey: "deviceConnections") else { return [] }
        return (try? JSONDecoder.codex.decode([DeviceConnection].self, from: data)) ?? []
    }
    private func saveSnapshotCache() { if let data = try? JSONEncoder.codex.encode(snapshots) { UserDefaults.standard.set(data, forKey: "snapshotCache") } }
    private func loadSnapshotCache() -> [Snapshot] { guard let data = UserDefaults.standard.data(forKey: "snapshotCache") else { return [] }; return (try? JSONDecoder.codex.decode([Snapshot].self, from: data)) ?? [] }
    private func applyHealthStates(now: Date = .now) {
        for index in snapshots.indices {
            let age = now.timeIntervalSince(snapshots[index].device.lastSeenAt)
            if age > 120 { snapshots[index].device.onlineState = .offline }
            else if age > 45 { snapshots[index].device.onlineState = .stale }
            else if snapshots[index].device.onlineState == .stale || snapshots[index].device.onlineState == .offline { snapshots[index].device.onlineState = .online }
        }
    }

    private func refreshTiboAnnouncement() async {
        guard let announcement = try? await tiboProvider.latestAnnouncement() else { return }
        if let index = snapshots.indices.first(where: { snapshots[$0].tiboAnnouncement?.observedAt ?? .distantPast < announcement.observedAt }) {
            snapshots[index].tiboAnnouncement = announcement
            saveSnapshotCache()
        }
    }

    struct RemoteState {
        var items: [RemoteStreamItem]
        var approval: RemoteApprovalRequest?
        var resolvedApprovalRequestId: String?
        var cursor: Int
    }

    func openRemoteSession(_ session: SessionSummary) async throws -> RemoteState {
        guard session.capabilities.readable else { throw RelayError.server("This session is not readable") }
        guard !connections.isEmpty else { return RemoteState(items: [], approval: nil, resolvedApprovalRequestId: nil, cursor: 0) }
        guard let connection = connections.first(where: { $0.id == session.key.deviceId }), let baseURL = try? relayBaseURL() else { throw RelayError.server("Target device is not paired") }
        let command = RemoteCommand(id: UUID().uuidString, kind: .open, sessionKey: session.key, createdAt: .now, expiresAt: .now.addingTimeInterval(30))
        try await relay.sendRemote(baseURL: baseURL, connection: connection, command: command)
        var response = try await relay.remoteEvents(baseURL: baseURL, connection: connection, session: session.key, after: 0)
        if response.capabilities == nil {
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(500))
                response = try await relay.remoteEvents(baseURL: baseURL, connection: connection, session: session.key, after: 0)
                if response.capabilities != nil || response.items.contains(where: { $0.kind == .error }) { break }
            }
        }
        applyRemoteMetadata(response, to: session)
        return RemoteState(items: response.items, approval: response.approval, resolvedApprovalRequestId: response.resolvedApprovalRequestId, cursor: response.cursor)
    }

    func pollRemoteSession(_ session: SessionSummary, after cursor: Int) async throws -> RemoteState {
        guard let connection = connections.first(where: { $0.id == session.key.deviceId }), let baseURL = try? relayBaseURL() else {
            return RemoteState(items: [], approval: nil, resolvedApprovalRequestId: nil, cursor: cursor)
        }
        let response = try await relay.remoteEvents(baseURL: baseURL, connection: connection, session: session.key, after: cursor)
        applyRemoteMetadata(response, to: session)
        return RemoteState(items: response.items, approval: response.approval, resolvedApprovalRequestId: response.resolvedApprovalRequestId, cursor: response.cursor)
    }

    func listenRemoteSession(_ session: SessionSummary, receive: @escaping (RemoteState) -> Void) async throws {
        guard let connection = connections.first(where: { $0.id == session.key.deviceId }), let baseURL = try? relayBaseURL() else { return }
        let stream = try await relay.remoteEventStream(baseURL: baseURL, connection: connection, sessionKey: session.key)
        for try await response in stream {
            applyRemoteMetadata(response, to: session)
            receive(RemoteState(items: response.items, approval: response.approval, resolvedApprovalRequestId: response.resolvedApprovalRequestId, cursor: response.cursor))
        }
    }

    func sendRemote(_ text: String, to session: SessionSummary) async throws {
        try await sendCommand(.init(id: UUID().uuidString, kind: session.capabilities.steerable ? .steer : .start, sessionKey: session.key, expectedTurnId: session.activeTurnId, text: text, createdAt: .now, expiresAt: .now.addingTimeInterval(30)), session: session)
    }

    func interruptRemote(_ session: SessionSummary, turnID: String) async throws {
        try await sendCommand(.init(id: UUID().uuidString, kind: .interrupt, sessionKey: session.key, expectedTurnId: turnID, createdAt: .now, expiresAt: .now.addingTimeInterval(15)), session: session)
    }

    func respondToApproval(_ session: SessionSummary, requestID: String, allowed: Bool) async throws {
        guard !requestID.isEmpty else { throw RelayError.server("Approval request expired") }
        try await sendCommand(.init(id: UUID().uuidString, kind: .approvalResponse, sessionKey: session.key, approvalRequestId: requestID, approved: allowed, createdAt: .now, expiresAt: .now.addingTimeInterval(30)), session: session)
    }

    func closeRemoteSession(_ session: SessionSummary) async {
        try? await sendCommand(.init(id: UUID().uuidString, kind: .close, sessionKey: session.key, createdAt: .now, expiresAt: .now.addingTimeInterval(10)), session: session)
    }

    private func sendCommand(_ command: RemoteCommand, session: SessionSummary) async throws {
        guard session.key.accountFingerprint == selectedFingerprint(for: session.key.deviceId) else { throw RelayError.server("Current device account does not match the session") }
        guard let connection = connections.first(where: { $0.id == session.key.deviceId }), let baseURL = try? relayBaseURL() else { throw RelayError.server("Target device is not connected") }
        try await relay.sendRemote(baseURL: baseURL, connection: connection, command: command)
    }

    private func selectedFingerprint(for deviceID: String) -> String? {
        guard let snapshot = snapshots.first(where: { $0.device.id == deviceID }), let presence = snapshot.presences.first(where: \.isCurrent) else { return nil }
        return presence.accountId
    }

    private func applyRemoteMetadata(_ response: RemoteEventsResponse, to session: SessionSummary) {
        guard let index = snapshots.firstIndex(where: { $0.device.id == session.key.deviceId }),
              let row = snapshots[index].sessionSummaries?.firstIndex(where: { $0.id == session.id }) else { return }
        if let capabilities = response.capabilities {
            snapshots[index].sessionSummaries?[row].capabilities = capabilities
            snapshots[index].sessionSummaries?[row].runtimeState = capabilities.active ? .active : .idle
        }
        snapshots[index].sessionSummaries?[row].activeTurnId = response.activeTurnId
    }
}
