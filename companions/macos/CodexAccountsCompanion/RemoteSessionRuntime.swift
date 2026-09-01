import Foundation

actor RemoteSessionRuntime {
    typealias UsageHandler = @Sendable (UsageObservation) async -> Void

    private enum JSONRPCID: Hashable {
        case integer(Int)
        case string(String)

        init?(_ value: Any?) {
            if let value = value as? Int { self = .integer(value) }
            else if let value = value as? String { self = .string(value) }
            else { return nil }
        }

        var wireValue: Any {
            switch self { case .integer(let value): value; case .string(let value): value }
        }

        var opaqueValue: String {
            switch self { case .integer(let value): String(value); case .string(let value): value }
        }
    }

    private struct PendingApproval {
        let rpcID: JSONRPCID
        let method: String
        let requestedPermissions: [String: Any]?
    }

    private struct OwnedSession {
        let profile: LocalProfile
        let accountFingerprint: String
        let process: Process
        let channel: RemoteJSONLChannel
        var activeTurnId: String?
        var ownsActiveTurn = false
        var pendingApprovals: [String: PendingApproval] = [:]
    }

    private var sessions: [String: OwnedSession] = [:]

    func handle(
        _ command: RemoteCommand,
        profiles: [LocalProfile],
        device: Device,
        relay: DesktopRelay,
        pairing: DesktopPairing,
        baseURL: URL,
        onUsage: @escaping UsageHandler
    ) async throws {
        guard command.expiresAt > .now, command.sessionKey.deviceId == device.id else {
            throw AppServerError.rpc("Remote command identity or expiry is invalid")
        }
        switch command.kind {
        case .open, .read:
            try await open(command, profiles: profiles, device: device, relay: relay, pairing: pairing, baseURL: baseURL, onUsage: onUsage)
        case .start, .steer, .interrupt, .approvalResponse:
            try await execute(command, relay: relay, pairing: pairing, baseURL: baseURL)
        case .close:
            await close(command.sessionKey)
        }
    }

    private func open(
        _ command: RemoteCommand,
        profiles: [LocalProfile],
        device: Device,
        relay: DesktopRelay,
        pairing: DesktopPairing,
        baseURL: URL,
        onUsage: @escaping UsageHandler
    ) async throws {
        let sessionID = storageKey(command.sessionKey)
        if sessions[sessionID] != nil {
            try await publishCapabilities(command.sessionKey, relay: relay, pairing: pairing, baseURL: baseURL)
            return
        }
        guard let profile = try await profile(matching: command.sessionKey.accountFingerprint, profiles: profiles, deviceID: device.id) else {
            throw AppServerError.rpc("No matching account environment on this device")
        }

        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: profile.codexBinary)
        process.arguments = profile.codexBinary == "/usr/bin/env" ? ["codex", "app-server", "--stdio"] : ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if !profile.codexHome.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = profile.codexHome
            process.environment = environment
        }
        try process.run()

        let channel = RemoteJSONLChannel(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        sessions[sessionID] = OwnedSession(
            profile: profile,
            accountFingerprint: command.sessionKey.accountFingerprint,
            process: process,
            channel: channel,
            activeTurnId: nil
        )
        await channel.start { [weak self] value in
            await self?.consume(
                value,
                sessionID: sessionID,
                key: command.sessionKey,
                device: device,
                relay: relay,
                pairing: pairing,
                baseURL: baseURL,
                onUsage: onUsage
            )
        }

        do {
            _ = try await channel.call(method: "initialize", params: [
                "clientInfo": ["name": "quota_pool_companion", "title": "Quota Pool Companion", "version": "1.1.0"]
            ])
            try await channel.send(["method": "initialized", "params": [:]])
            let readResponse = try await channel.call(method: "thread/read", params: [
                "threadId": command.sessionKey.threadId,
                "includeTurns": true
            ])
            let history = transcriptItems(from: readResponse)

            // A successful resume is the proof that this Companion process can own this
            // persisted thread. It is not proof that an arbitrary Codex Desktop foreground
            // turn is steerable, so active-turn controls stay gated separately.
            let resumeResponse = try await channel.call(method: "thread/resume", params: [
                "threadId": command.sessionKey.threadId
            ])
            if var owned = sessions[sessionID] {
                owned.activeTurnId = activeTurnID(from: resumeResponse)
                owned.ownsActiveTurn = false
                sessions[sessionID] = owned
            }
            try await relay.publishRemoteEvent(
                pairing: pairing,
                baseURL: baseURL,
                accountFingerprint: command.sessionKey.accountFingerprint,
                threadId: command.sessionKey.threadId,
                items: history,
                capabilities: sessions[sessionID].map(capabilities),
                approval: nil,
                resolvedApprovalRequestId: nil,
                activeTurnId: sessions[sessionID]?.activeTurnId
            )
        } catch {
            await close(command.sessionKey)
            throw error
        }
    }

    private func execute(_ command: RemoteCommand, relay: DesktopRelay, pairing: DesktopPairing, baseURL: URL) async throws {
        let sessionID = storageKey(command.sessionKey)
        guard var owned = sessions[sessionID], owned.accountFingerprint == command.sessionKey.accountFingerprint else {
            throw AppServerError.rpc("The companion has not taken over this session")
        }
        var resolvedApprovalID: String?
        switch command.kind {
        case .start:
            guard let text = command.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, owned.activeTurnId == nil else {
                throw AppServerError.rpc("This session cannot start a new turn")
            }
            let response = try await owned.channel.call(method: "turn/start", params: [
                "threadId": command.sessionKey.threadId,
                "input": [["type": "text", "text": text, "text_elements": []]]
            ])
            owned.activeTurnId = ((response["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String
            owned.ownsActiveTurn = owned.activeTurnId != nil
        case .steer:
            guard owned.ownsActiveTurn, let text = command.text, let turnID = owned.activeTurnId, turnID == command.expectedTurnId else {
                throw AppServerError.rpc("Active turn identity does not match or is not steerable")
            }
            _ = try await owned.channel.call(method: "turn/steer", params: [
                "threadId": command.sessionKey.threadId,
                "expectedTurnId": turnID,
                "input": [["type": "text", "text": text, "text_elements": []]]
            ])
        case .interrupt:
            guard owned.ownsActiveTurn, let turnID = owned.activeTurnId, turnID == command.expectedTurnId else {
                throw AppServerError.rpc("No matching turn to stop")
            }
            _ = try await owned.channel.call(method: "turn/interrupt", params: [
                "threadId": command.sessionKey.threadId,
                "turnId": turnID
            ])
        case .approvalResponse:
            guard let requestID = command.approvalRequestId,
                  let pending = owned.pendingApprovals.removeValue(forKey: requestID),
                  let approved = command.approved else {
                throw AppServerError.rpc("Approval request is missing or already resolved")
            }
            let result: [String: Any]
            if pending.method == "item/permissions/requestApproval" {
                result = ["permissions": approved ? (pending.requestedPermissions ?? [:]) : [:], "scope": "turn"]
            } else {
                result = ["decision": approved ? "accept" : "decline"]
            }
            try await owned.channel.send(["id": pending.rpcID.wireValue, "result": result])
            resolvedApprovalID = requestID
        default:
            break
        }
        sessions[sessionID] = owned
        try await relay.publishRemoteEvent(
            pairing: pairing,
            baseURL: baseURL,
            accountFingerprint: command.sessionKey.accountFingerprint,
            threadId: command.sessionKey.threadId,
            items: [],
            capabilities: capabilities(owned),
            approval: nil,
            resolvedApprovalRequestId: resolvedApprovalID,
            activeTurnId: owned.activeTurnId
        )
    }

    private func consume(
        _ value: [String: Any],
        sessionID: String,
        key: SessionKey,
        device: Device,
        relay: DesktopRelay,
        pairing: DesktopPairing,
        baseURL: URL,
        onUsage: @escaping UsageHandler
    ) async {
        guard var owned = sessions[sessionID] else { return }

        if let rpcID = JSONRPCID(value["id"]), let method = value["method"] as? String, approvalMethods.contains(method) {
            let params = value["params"] as? [String: Any] ?? [:]
            let requestID = rpcID.opaqueValue
            owned.pendingApprovals[requestID] = PendingApproval(
                rpcID: rpcID,
                method: method,
                requestedPermissions: params["permissions"] as? [String: Any]
            )
            sessions[sessionID] = owned
            let approval = RemoteApprovalRequest(
                id: requestID,
                sessionKey: key,
                kind: method.contains("fileChange") ? .fileChange : method.contains("permissions") ? .permissions : .commandExecution,
                title: approvalTitle(method: method, params: params),
                detail: approvalDetail(method: method, params: params),
                createdAt: .now
            )
            try? await relay.publishRemoteEvent(
                pairing: pairing,
                baseURL: baseURL,
                accountFingerprint: key.accountFingerprint,
                threadId: key.threadId,
                items: [],
                capabilities: capabilities(owned),
                approval: approval,
                resolvedApprovalRequestId: nil,
                activeTurnId: owned.activeTurnId
            )
            return
        }

        guard let method = value["method"] as? String else { return }
        let params = value["params"] as? [String: Any] ?? [:]

        if method == "thread/tokenUsage/updated", let cumulative = tokenBreakdown(from: params) {
            await onUsage(UsageObservation(
                deviceId: device.id,
                deviceName: device.name,
                accountFingerprint: key.accountFingerprint,
                threadId: key.threadId,
                observedAt: .now,
                cumulative: cumulative
            ))
        }

        var resolvedApprovalID: String?
        if method == "serverRequest/resolved", let raw = params["requestId"] {
            resolvedApprovalID = JSONRPCID(raw)?.opaqueValue ?? String(describing: raw)
            if let resolvedApprovalID { owned.pendingApprovals.removeValue(forKey: resolvedApprovalID) }
        }

        if method == "turn/started", let turn = params["turn"] as? [String: Any] {
            owned.activeTurnId = turn["id"] as? String
            // Only turns started by a remote command are considered steerable. A notification
            // observed immediately after resume may belong to another client.
        } else if method == "turn/completed" {
            owned.activeTurnId = nil
            owned.ownsActiveTurn = false
        }
        sessions[sessionID] = owned

        let item = streamItem(method: method, params: params)
        guard item != nil || resolvedApprovalID != nil || method == "turn/started" || method == "turn/completed" else { return }
        try? await relay.publishRemoteEvent(
            pairing: pairing,
            baseURL: baseURL,
            accountFingerprint: key.accountFingerprint,
            threadId: key.threadId,
            items: item.map { [$0] } ?? [],
            capabilities: capabilities(owned),
            approval: nil,
            resolvedApprovalRequestId: resolvedApprovalID,
            activeTurnId: owned.activeTurnId
        )
    }

    private var approvalMethods: Set<String> {
        ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"]
    }

    private func streamItem(method: String, params: [String: Any]) -> RemoteStreamItem? {
        let now = Date()
        switch method {
        case "item/agentMessage/delta":
            let itemID = params["itemId"] as? String ?? UUID().uuidString
            return .init(id: "agent:\(itemID)", kind: .agent, text: params["delta"] as? String ?? "", state: .running, createdAt: now, append: true)
        case "turn/started":
            return .init(id: "turn-status", kind: .status, text: "Codex is running", state: .running, createdAt: now)
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String ?? "completed"
            let state: RemoteStreamItemState = status == "interrupted" ? .interrupted : status == "failed" ? .failed : .completed
            let text = status == "interrupted" ? "Turn stopped" : status == "failed" ? "Turn failed" : "Turn completed"
            return .init(id: "turn-status", kind: .status, text: text, state: state, createdAt: now)
        case "turn/plan/updated":
            return .init(id: "plan:\(params["turnId"] as? String ?? UUID().uuidString)", kind: .plan, text: planText(params), state: .running, createdAt: now)
        case "turn/diff/updated":
            return .init(id: UUID().uuidString, kind: .fileChange, text: "File changes updated", state: .running, createdAt: now)
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let type = item["type"] as? String else { return nil }
            let completed = method == "item/completed"
            switch type {
            case "commandExecution":
                let command = item["command"] as? String
                return .init(id: "command:\(item["id"] as? String ?? UUID().uuidString)", kind: .command, text: command.map { completed ? "Finished: \($0)" : "Running: \($0)" } ?? (completed ? "Command finished" : "Running a command"), state: completed ? .completed : .running, createdAt: now)
            case "fileChange":
                return .init(id: "file:\(item["id"] as? String ?? UUID().uuidString)", kind: .fileChange, text: completed ? "File changes completed" : "Editing files", state: completed ? .completed : .running, createdAt: now)
            default:
                return nil
            }
        case "error":
            return .init(id: UUID().uuidString, kind: .error, text: ((params["error"] as? [String: Any])?["message"] as? String) ?? "Codex error", state: .failed, createdAt: now)
        default:
            return nil
        }
    }

    private func transcriptItems(from response: [String: Any]) -> [RemoteStreamItem] {
        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]] else { return [] }
        var output: [RemoteStreamItem] = []
        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items {
                let type = item["type"] as? String ?? ""
                if type == "userMessage", let text = userVisibleText(item), !text.isEmpty {
                    output.append(.init(id: "history-user:\(item["id"] as? String ?? UUID().uuidString)", kind: .user, text: text, state: .completed, createdAt: .now))
                } else if type == "agentMessage", let text = userVisibleText(item), !text.isEmpty {
                    output.append(.init(id: "history-agent:\(item["id"] as? String ?? UUID().uuidString)", kind: .agent, text: text, state: .completed, createdAt: .now))
                }
            }
        }
        return output
    }

    private func userVisibleText(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            return array.compactMap(userVisibleText).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard let object = value as? [String: Any] else { return nil }
        if let text = object["text"] as? String { return text }
        if let content = object["content"] { return userVisibleText(content) }
        return nil
    }

    private func tokenBreakdown(from params: [String: Any]) -> TokenBreakdown? {
        guard let usage = params["tokenUsage"] as? [String: Any], let total = usage["total"] as? [String: Any] else { return nil }
        func integer(_ key: String) -> Int64 { (total[key] as? NSNumber)?.int64Value ?? 0 }
        return .init(
            inputTokens: integer("inputTokens"),
            cachedInputTokens: integer("cachedInputTokens"),
            outputTokens: integer("outputTokens"),
            reasoningTokens: integer("reasoningOutputTokens"),
            totalTokens: integer("totalTokens")
        )
    }

    private func activeTurnID(from response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any], let thread = result["thread"] as? [String: Any] else { return nil }
        if let status = thread["status"] as? [String: Any], status["type"] as? String == "active" {
            return (thread["turns"] as? [[String: Any]])?.last?["id"] as? String
        }
        return nil
    }

    private func planText(_ params: [String: Any]) -> String {
        guard let plan = params["plan"] as? [[String: Any]] else { return "Plan updated" }
        let lines = plan.compactMap { row -> String? in
            guard let step = row["step"] as? String else { return nil }
            return "• \(step)"
        }
        return lines.isEmpty ? "Plan updated" : lines.joined(separator: "\n")
    }

    private func approvalTitle(method: String, params: [String: Any]) -> String {
        if params["networkApprovalContext"] != nil { return "Network-access approval required" }
        if method.contains("fileChange") { return "File-change approval required" }
        if method.contains("permissions") { return "Permission approval required" }
        return "Command execution approval required"
    }

    private func approvalDetail(method: String, params: [String: Any]) -> String {
        var details: [String] = []
        if let reason = params["reason"] as? String, !reason.isEmpty { details.append(reason) }
        if let command = params["command"] as? String, !command.isEmpty { details.append(command) }
        if let cwd = params["cwd"] as? String, !cwd.isEmpty { details.append("Location: \(cwd)") }
        if let root = params["grantRoot"] as? String, !root.isEmpty { details.append("Write scope: \(root)") }
        if details.isEmpty { details.append(method.contains("permissions") ? "Codex is requesting extra sandbox permission" : "Codex is waiting for your decision") }
        return details.joined(separator: "\n")
    }

    private func capabilities(_ session: OwnedSession) -> SessionCapabilities {
        .init(
            readable: true,
            resumable: true,
            writable: true,
            active: session.activeTurnId != nil,
            steerable: session.ownsActiveTurn && session.activeTurnId != nil,
            interruptible: session.ownsActiveTurn && session.activeTurnId != nil,
            approvalCapable: true
        )
    }

    private func publishCapabilities(_ key: SessionKey, relay: DesktopRelay, pairing: DesktopPairing, baseURL: URL) async throws {
        if let owned = sessions[storageKey(key)] {
            try await relay.publishRemoteEvent(
                pairing: pairing,
                baseURL: baseURL,
                accountFingerprint: key.accountFingerprint,
                threadId: key.threadId,
                items: [],
                capabilities: capabilities(owned),
                approval: nil,
                resolvedApprovalRequestId: nil,
                activeTurnId: owned.activeTurnId
            )
        }
    }

    private func close(_ key: SessionKey) async {
        guard let owned = sessions.removeValue(forKey: storageKey(key)) else { return }
        await owned.channel.shutdown()
        if owned.process.isRunning { owned.process.terminate() }
    }

    private func profile(matching fingerprint: String, profiles: [LocalProfile], deviceID: String) async throws -> LocalProfile? {
        let client = AppServerClient()
        for profile in profiles {
            if try await client.observe(profile: profile, deviceID: deviceID).account.id == fingerprint { return profile }
        }
        return nil
    }

    private func storageKey(_ key: SessionKey) -> String {
        "\(key.deviceId):\(key.accountFingerprint):\(key.threadId)"
    }
}

private actor RemoteJSONLChannel {
    typealias EventHandler = @Sendable ([String: Any]) async -> Void

    private let input: FileHandle
    private let output: FileHandle
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var handler: EventHandler?
    private var readerTask: Task<Void, Never>?
    private var terminalError: Error?

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func start(handler: @escaping EventHandler) {
        guard readerTask == nil else { return }
        self.handler = handler
        let output = self.output
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var buffer = Data()
                while !Task.isCancelled {
                    if let newline = buffer.firstIndex(of: 0x0a) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard !line.isEmpty else { continue }
                        guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                            throw AppServerError.malformed("Codex returned invalid JSON")
                        }
                        await self?.deliver(value)
                        continue
                    }
                    guard let chunk = try output.read(upToCount: 4_096), !chunk.isEmpty else {
                        throw AppServerError.malformed("Codex App Server closed")
                    }
                    buffer.append(chunk)
                }
            } catch {
                await self?.finish(error)
            }
        }
    }

    func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        if let terminalError { throw terminalError }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(["method": method, "id": id, "params": params]) }
            catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func send(_ value: [String: Any]) throws {
        if let terminalError { throw terminalError }
        try write(value)
    }

    func shutdown() {
        readerTask?.cancel()
        readerTask = nil
        try? input.close()
        try? output.close()
        finish(AppServerError.malformed("Remote session closed"))
    }

    private func deliver(_ value: [String: Any]) async {
        if let id = value["id"] as? Int, value["method"] == nil, let continuation = pending.removeValue(forKey: id) {
            if let error = value["error"] as? [String: Any] {
                continuation.resume(throwing: AppServerError.rpc(error["message"] as? String ?? "App Server request failed"))
            } else {
                continuation.resume(returning: value)
            }
            return
        }
        await handler?(value)
    }

    private func finish(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func write(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(0x0a)
        try input.write(contentsOf: data)
    }
}
