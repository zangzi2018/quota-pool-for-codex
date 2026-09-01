import Foundation
import Observation

@MainActor @Observable
final class CompanionModel {
    var profiles: [LocalProfile] = []
    var relayURL = UserDefaults.standard.string(forKey: "relayURL") ?? "http://127.0.0.1:8787"
    var pairingCode = ""
    var pairing: DesktopPairing?
    var lastSnapshot: Snapshot?
    var isWorking = false
    var status = "Not synced yet"
    var errorMessage: String?
    var pairingFingerprint = ""
    var globalResets: [GlobalRateLimitReset] = []
    private var usageAccumulator = UsageAccumulator()
    private var lastUsageUploadAt = Date.distantPast
    private let appServer = AppServerClient()
    private let relay = DesktopRelay()
    private let remoteRuntime = RemoteSessionRuntime()
    private var processingCommandIDs: Set<String> = []

    init() {
        profiles = load([LocalProfile].self, key: "profiles") ?? []
        pairing = load(DesktopPairing.self, key: "pairing")
        lastSnapshot = load(Snapshot.self, key: "lastSnapshot")
        globalResets = load([GlobalRateLimitReset].self, key: "globalResets") ?? []
        usageAccumulator = load(UsageAccumulator.self, key: "usageAccumulator") ?? UsageAccumulator()
        if profiles.isEmpty { profiles = [LocalProfile(alias: "", codexHome: "", isCurrent: true)] }
        for index in profiles.indices where profiles[index].alias == "My account" || profiles[index].alias == "New account" {
            profiles[index].alias = ""
        }
    }

    var device: Device {
        Device(id: deviceID, name: Host.current().localizedName ?? "My Mac", platform: .macOS, osVersion: ProcessInfo.processInfo.operatingSystemVersionString, codexVersion: "dynamic", onlineState: .online, lastSeenAt: .now)
    }

    func saveSettings() {
        normalizeCurrentProfile()
        do {
            let parsed = try RelayURLPolicy.parse(relayURL)
            relayURL = parsed.url.absoluteString
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        save(profiles, key: "profiles"); save(pairing, key: "pairing"); UserDefaults.standard.set(relayURL, forKey: "relayURL")
    }

    func pair() async {
        guard pairingCode.filter(\.isNumber).count == 6, let url = try? RelayURLPolicy.parse(relayURL).url else { errorMessage = "Enter a 6-digit pairing code. Public relays must use HTTPS."; return }
        isWorking = true; status = "Waiting for iPhone confirmation"; defer { isWorking = false }
        do {
            pairing = try await relay.pair(code: pairingCode.filter(\.isNumber), baseURL: url, device: device) { fingerprint in
                await MainActor.run { self.pairingFingerprint = fingerprint; self.status = "Confirm the security fingerprint on iPhone" }
            }
            saveSettings(); status = "Paired"; await sync()
        }
        catch { errorMessage = error.localizedDescription; status = "Pairing failed" }
    }

    func sync() async {
        guard let pairing, let url = try? RelayURLPolicy.parse(relayURL).url else { status = pairing == nil ? "Connect iPhone first" : "Relay URL is invalid or not HTTPS"; return }
        normalizeCurrentProfile()
        isWorking = true; status = "Reading local Codex"; defer { isWorking = false }
        do {
            var observations: [ProfileObservation] = []
            for profile in profiles { observations.append(try await appServer.observe(profile: profile, deviceID: deviceID)) }
            let now = Date()
            let accounts = Dictionary(grouping: observations.map(\.account), by: \.id).values.compactMap { $0.first }
            let presences = Dictionary(grouping: observations.map(\.presence), by: \.accountId).values.compactMap { items in items.sorted { $0.isCurrent && !$1.isCurrent }.first }
            let windows = Dictionary(grouping: observations.flatMap(\.windows), by: \.id).values.compactMap { $0.max(by: { $0.observedAt < $1.observedAt }) }
            let summaries = Dictionary(grouping: observations.map(\.credits), by: \.accountId).map { accountID, values in
                let returned = values.flatMap { $0.credits ?? [] }
                let details = returned.isEmpty && values.allSatisfy { $0.credits == nil } ? nil : Array(Dictionary(grouping: returned, by: \.id).values.compactMap { $0.first })
                return ResetCreditSummary(accountId: accountID, availableCount: values.map(\.availableCount).max() ?? 0, credits: details)
            }
            let sessions = Dictionary(grouping: observations.flatMap(\.sessions), by: \.id).values.compactMap { $0.max(by: { $0.updatedAt < $1.updatedAt }) }
            let activity = SnapshotDiff.activity(previous: lastSnapshot, accounts: accounts, presences: presences, windows: windows, summaries: summaries, device: device, now: now)
            let snapshot = Snapshot(device: device, accounts: accounts, presences: presences, rateLimitWindows: windows, resetCreditSummaries: summaries, globalRateLimitResets: globalResets, activity: activity, observedAt: now, sessionSummaries: sessions, deviceUsageDays: usageAccumulator.days)
            try await relay.upload(snapshot: snapshot, pairing: pairing, baseURL: url)
            lastSnapshot = snapshot; save(snapshot, key: "lastSnapshot"); status = "Synced \(snapshot.accounts.count) accounts"
        } catch { errorMessage = error.localizedDescription; status = "Sync failed" }
    }

    func pollRemoteCommands() async {
        guard let pairing, let url = try? RelayURLPolicy.parse(relayURL).url else { return }
        do {
            for command in try await relay.pendingRemoteCommands(pairing: pairing, baseURL: url) { await handleRemoteCommand(command, pairing: pairing, baseURL: url) }
        } catch { /* Presence/snapshot sync reports Relay failures; polling remains silent. */ }
    }

    func runRelayConnection() async {
        while !Task.isCancelled {
            guard let pairing, let url = try? RelayURLPolicy.parse(relayURL).url else {
                try? await Task.sleep(for: .seconds(2)); continue
            }
            do {
                let stream = try await relay.remoteCommandStream(pairing: pairing, baseURL: url)
                for try await command in stream { await handleRemoteCommand(command, pairing: pairing, baseURL: url) }
            } catch is CancellationError { return }
            catch { try? await Task.sleep(for: .seconds(2)) }
        }
    }

    private func handleRemoteCommand(_ command: RemoteCommand, pairing: DesktopPairing, baseURL: URL) async {
        guard processingCommandIDs.insert(command.id).inserted else { return }
        do {
            try await remoteRuntime.handle(
                command,
                profiles: profiles,
                device: device,
                relay: relay,
                pairing: pairing,
                baseURL: baseURL
            ) { [weak self] observation in
                await self?.recordUsage(observation)
            }
        } catch {
            try? await relay.publishRemoteEvent(
                pairing: pairing,
                baseURL: baseURL,
                accountFingerprint: command.sessionKey.accountFingerprint,
                threadId: command.sessionKey.threadId,
                items: [RemoteStreamItem(id: UUID().uuidString, kind: .error, text: error.localizedDescription, state: .failed, createdAt: .now)],
                capabilities: nil,
                approval: nil,
                resolvedApprovalRequestId: nil,
                activeTurnId: nil
            )
        }
        try? await relay.acknowledgeRemoteCommand(command.id, pairing: pairing, baseURL: baseURL)
    }

    func addProfile() { profiles.append(LocalProfile(alias: "", codexHome: "")); saveSettings() }
    func recordVerifiedGlobalReset() { globalResets.insert(GlobalRateLimitReset(id: UUID().uuidString, occurredAt: .now, source: .official, note: "Confirmed on desktop: applied to all users at the same time"), at: 0); globalResets = Array(globalResets.prefix(100)); save(globalResets, key: "globalResets") }
    func removeProfiles(at offsets: IndexSet) { profiles.remove(atOffsets: offsets); if !profiles.contains(where: \.isCurrent), !profiles.isEmpty { profiles[0].isCurrent = true }; saveSettings() }

    private func normalizeCurrentProfile() {
        guard !profiles.isEmpty else { return }
        let selected = profiles.firstIndex(where: \.isCurrent) ?? 0
        for index in profiles.indices { profiles[index].isCurrent = index == selected }
    }

    private func recordUsage(_ observation: UsageObservation) async {
        let delta = usageAccumulator.observe(observation)
        save(usageAccumulator, key: "usageAccumulator")
        guard delta.totalTokens > 0, var snapshot = lastSnapshot else { return }
        snapshot.deviceUsageDays = usageAccumulator.days
        snapshot.observedAt = .now
        snapshot.device.lastSeenAt = .now
        lastSnapshot = snapshot
        save(snapshot, key: "lastSnapshot")

        // Token notifications can be frequent. Persist every observation locally, while
        // coalescing encrypted Relay snapshot uploads to at most one every two seconds.
        guard Date.now.timeIntervalSince(lastUsageUploadAt) >= 2,
              let pairing,
              let url = try? RelayURLPolicy.parse(relayURL).url else { return }
        lastUsageUploadAt = .now
        try? await relay.upload(snapshot: snapshot, pairing: pairing, baseURL: url)
    }

    private var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: "deviceID") { return existing }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: "deviceID"); return value
    }
    private func save<T: Encodable>(_ value: T, key: String) { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; UserDefaults.standard.set(try? encoder.encode(value), forKey: key) }
    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? { guard let data = UserDefaults.standard.data(forKey: key) else { return nil }; let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try? decoder.decode(type, from: data) }
}
