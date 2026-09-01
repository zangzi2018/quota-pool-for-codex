import CryptoKit
import Foundation

enum AppServerError: LocalizedError {
    case launch(String), malformed(String), rpc(String), noAccount
    var errorDescription: String? { switch self { case .launch(let s), .malformed(let s), .rpc(let s): s; case .noAccount: "This local profile is not signed in to ChatGPT" } }
}

struct LocalProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var alias: String
    var codexHome: String
    var codexBinary: String = "/usr/bin/env"
    var isCurrent = false
}

struct ProfileObservation {
    let account: Account
    let presence: AccountPresence
    let windows: [RateLimitWindow]
    let credits: ResetCreditSummary
    let sessions: [SessionSummary]
}

actor AppServerClient {
    private var nextID = 1

    func observe(profile: LocalProfile, deviceID: String) throws -> ProfileObservation {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: profile.codexBinary)
        process.arguments = profile.codexBinary == "/usr/bin/env" ? ["codex", "app-server", "--stdio"] : ["app-server", "--stdio"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        if !profile.codexHome.isEmpty { var environment = ProcessInfo.processInfo.environment; environment["CODEX_HOME"] = profile.codexHome; process.environment = environment }
        do { try process.run() } catch { throw AppServerError.launch("Unable to start Codex: \(error.localizedDescription)") }
        defer { if process.isRunning { process.terminate() } }
        let channel = JSONLChannel(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        let initialize = try call(channel, method: "initialize", params: ["clientInfo": ["name": "quota_pool_companion", "title": "Quota Pool Companion", "version": "1.1.0"]])
        guard initialize["result"] != nil else { throw AppServerError.rpc("Codex initialization failed") }
        try channel.send(["method": "initialized", "params": [:]])
        let accountMessage = try call(channel, method: "account/read", params: ["refreshToken": false])
        guard let result = accountMessage["result"] as? [String: Any], let rawAccount = result["account"] as? [String: Any], rawAccount["type"] as? String == "chatgpt" else { throw AppServerError.noAccount }
        let email = (rawAccount["email"] as? String) ?? "unknown@local"
        let accountID = StableID.account(email)
        let account = Account(id: accountID, email: email, alias: profile.alias.isEmpty ? nil : profile.alias, planType: (rawAccount["planType"] as? String) ?? "unknown", renewalAt: nil)
        let limitsMessage = try call(channel, method: "account/rateLimits/read", params: [:])
        let observationTime = Date()
        let limitResult = (limitsMessage["result"] as? [String: Any]) ?? [:]
        let buckets = RateLimitAdapter.buckets(from: limitResult)
        let windows = RateLimitAdapter.windows(buckets: buckets, accountID: accountID, observedAt: observationTime)
        let credits = RateLimitAdapter.credits(from: limitResult, accountID: accountID)
        let threadsMessage = try call(channel, method: "thread/list", params: ["limit": 50, "sortKey": "updated_at", "sortDirection": "desc"])
        let threadsResult = (threadsMessage["result"] as? [String: Any]) ?? [:]
        let sessions = ThreadAdapter.summaries(from: threadsResult, deviceID: deviceID, deviceName: Host.current().localizedName ?? "My Mac", account: account)
        return ProfileObservation(account: account, presence: AccountPresence(deviceId: deviceID, accountId: accountID, isCurrent: profile.isCurrent, profileKey: profile.id.uuidString, lastSeenAt: observationTime), windows: windows, credits: credits, sessions: sessions)
    }

    private func call(_ channel: JSONLChannel, method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID; nextID += 1
        try channel.send(["method": method, "id": id, "params": params])
        while true { let value = try channel.receive(); if value["id"] as? Int == id { if let error = value["error"] as? [String: Any] { throw AppServerError.rpc((error["message"] as? String) ?? method) }; return value } }
    }
}

private final class JSONLChannel {
    let input: FileHandle, output: FileHandle
    private var buffer = Data()
    init(input: FileHandle, output: FileHandle) { self.input = input; self.output = output }
    func send(_ value: [String: Any]) throws { var data = try JSONSerialization.data(withJSONObject: value); data.append(0x0a); try input.write(contentsOf: data) }
    func receive() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw AppServerError.malformed("Codex returned invalid JSON") }
                return value
            }
            // Foundation may wait for the requested byte count on a pipe. Reading one byte
            // guarantees that a short JSONL response is returned as soon as its newline arrives.
            guard let chunk = try output.read(upToCount: 1), !chunk.isEmpty else { throw AppServerError.malformed("Codex App Server closed") }
            buffer.append(chunk)
        }
    }
}

enum StableID {
    static func account(_ email: String) -> String {
        SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum RateLimitAdapter {
    static func buckets(from result: [String: Any]) -> [[String: Any]] {
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] { return byID.values.compactMap { $0 as? [String: Any] } }
        return (result["rateLimits"] as? [String: Any]).map { [$0] } ?? []
    }
    static func windows(buckets: [[String: Any]], accountID: String, observedAt: Date) -> [RateLimitWindow] {
        buckets.flatMap { bucket in
            ["primary", "secondary"].compactMap { name -> RateLimitWindow? in
                guard let value = bucket[name] as? [String: Any], let duration = (value["windowDurationMins"] as? NSNumber)?.intValue, let used = (value["usedPercent"] as? NSNumber)?.doubleValue, let reset = (value["resetsAt"] as? NSNumber)?.doubleValue else { return nil }
                let limit = bucket["limitId"] as? String
                return RateLimitWindow(id: "\(accountID):\(limit ?? "default"):\(duration)", accountId: accountID, limitId: limit, durationMins: duration, usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset), observedAt: observedAt)
            }
        }
    }
    static func credits(from result: [String: Any], accountID: String) -> ResetCreditSummary {
        guard let raw = result["rateLimitResetCredits"] as? [String: Any] else { return ResetCreditSummary(accountId: accountID, availableCount: 0, credits: nil) }
        let count = (raw["availableCount"] as? NSNumber)?.intValue ?? 0
        let rows = (raw["credits"] as? [[String: Any]])?.compactMap { item -> ResetCredit? in
            guard let id = item["id"] as? String, let type = item["resetType"] as? String, let status = item["status"] as? String, let granted = (item["grantedAt"] as? NSNumber)?.doubleValue else { return nil }
            return ResetCredit(id: id, accountId: accountID, title: item["title"] as? String, resetType: type, status: status, grantedAt: Date(timeIntervalSince1970: granted), expiresAt: (item["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        return ResetCreditSummary(accountId: accountID, availableCount: count, credits: rows)
    }
}

enum ThreadAdapter {
    static func summaries(from result: [String: Any], deviceID: String, deviceName: String, account: Account) -> [SessionSummary] {
        ((result["data"] as? [[String: Any]]) ?? []).compactMap { thread in
            guard let threadID = thread["id"] as? String else { return nil }
            let statusObject = thread["status"] as? [String: Any]
            let rawStatus = statusObject?["type"] as? String ?? "notLoaded"
            let runtime = ThreadRuntimeState(rawValue: rawStatus) ?? .unavailable
            let title = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (thread["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let updated = (thread["recencyAt"] as? NSNumber)?.doubleValue ?? (thread["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            // A separately launched App Server can read persisted metadata, but this observation
            // does not prove ownership of a Desktop-active thread. Remote write flags stay off.
            let capabilities = SessionCapabilities(readable: true, resumable: false, writable: false, active: runtime == .active, steerable: false, interruptible: false, approvalCapable: false)
            return SessionSummary(
                key: SessionKey(deviceId: deviceID, accountFingerprint: account.id, threadId: threadID),
                title: title?.isEmpty == false ? title! : (preview.isEmpty ? "Untitled session" : preview),
                preview: preview,
                deviceName: deviceName,
                accountAlias: account.displayName,
                planType: account.planType,
                runtimeState: runtime,
                model: thread["modelProvider"] as? String,
                reasoningEffort: nil,
                activeTurnId: nil,
                updatedAt: Date(timeIntervalSince1970: updated),
                capabilities: capabilities
            )
        }
    }
}
