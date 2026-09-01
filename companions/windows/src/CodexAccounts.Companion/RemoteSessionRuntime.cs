using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;

namespace CodexAccounts.Companion;

public sealed class RemoteSessionRuntime
{
    private sealed record PendingApproval(JsonElement RpcId, string Method, JsonElement? RequestedPermissions);
    private sealed class OwnedSession(LocalProfile profile, Process process, JsonRpcChannel channel)
    {
        public LocalProfile Profile { get; } = profile;
        public Process Process { get; } = process;
        public JsonRpcChannel Channel { get; } = channel;
        public string? ActiveTurnId { get; set; }
        public bool OwnsActiveTurn { get; set; }
        public ConcurrentDictionary<string, PendingApproval> Approvals { get; } = new();
    }

    private readonly Dictionary<string, OwnedSession> _sessions = [];
    private readonly SemaphoreSlim _gate = new(1, 1);
    private static readonly HashSet<string> ApprovalMethods = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"];

    public async Task HandleAsync(RemoteCommand command, IReadOnlyList<LocalProfile> profiles, Device device, RelayClient relay, DesktopPairing pairing, Uri relayUri, Func<UsageObservation, Task> onUsage, CancellationToken cancellationToken)
    {
        if (command.ExpiresAt <= DateTimeOffset.UtcNow || command.SessionKey.DeviceId != device.Id) throw new InvalidOperationException("Remote command identity or expiry is invalid");
        switch (command.Kind)
        {
            case "open": case "read": await OpenAsync(command, profiles, device, relay, pairing, relayUri, onUsage, cancellationToken); break;
            case "start": case "steer": case "interrupt": case "approvalResponse": await ExecuteAsync(command, relay, pairing, relayUri, cancellationToken); break;
            case "close": await CloseAsync(command.SessionKey); break;
            default: throw new InvalidOperationException("Unsupported remote command");
        }
    }

    private async Task OpenAsync(RemoteCommand command, IReadOnlyList<LocalProfile> profiles, Device device, RelayClient relay, DesktopPairing pairing, Uri relayUri, Func<UsageObservation, Task> onUsage, CancellationToken cancellationToken)
    {
        var storageKey = StorageKey(command.SessionKey);
        await _gate.WaitAsync(cancellationToken);
        try {
            if (_sessions.TryGetValue(storageKey, out var existing)) {
                await relay.PublishRemoteEventAsync(relayUri, pairing, command.SessionKey, [], Capabilities(existing), activeTurnId: existing.ActiveTurnId, cancellationToken: cancellationToken);
                return;
            }
        } finally { _gate.Release(); }

        LocalProfile? matching = null;
        var observer = new AppServerClient();
        foreach (var profile in profiles) {
            if ((await observer.ObserveAsync(profile, device.Id, cancellationToken)).Account.Id == command.SessionKey.AccountFingerprint) { matching = profile; break; }
        }
        if (matching is null) throw new InvalidOperationException("No matching account environment on this device");

        var start = new ProcessStartInfo(matching.CodexBinary, "app-server --stdio") { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        if (!string.IsNullOrWhiteSpace(matching.CodexHome)) start.Environment["CODEX_HOME"] = matching.CodexHome;
        var process = Process.Start(start) ?? throw new InvalidOperationException("Unable to start Codex CLI");
        var channel = new JsonRpcChannel(process);
        var owned = new OwnedSession(matching, process, channel);
        await _gate.WaitAsync(cancellationToken);
        try { _sessions[storageKey] = owned; } finally { _gate.Release(); }
        channel.Start(value => ConsumeAsync(value, storageKey, command.SessionKey, device, relay, pairing, relayUri, onUsage, cancellationToken));

        try {
            await channel.CallAsync("initialize", new { clientInfo = new { name = "quota_pool_companion", title = "Quota Pool Companion", version = "1.1.0" } }, cancellationToken);
            await channel.SendAsync(new { method = "initialized", @params = new { } }, cancellationToken);
            var read = await channel.CallAsync("thread/read", new { threadId = command.SessionKey.ThreadId, includeTurns = true }, cancellationToken);
            var history = TranscriptItems(read);
            var resume = await channel.CallAsync("thread/resume", new { threadId = command.SessionKey.ThreadId }, cancellationToken);
            owned.ActiveTurnId = ActiveTurnId(resume);
            owned.OwnsActiveTurn = false;
            await relay.PublishRemoteEventAsync(relayUri, pairing, command.SessionKey, history, Capabilities(owned), activeTurnId: owned.ActiveTurnId, cancellationToken: cancellationToken);
        } catch {
            await CloseAsync(command.SessionKey);
            throw;
        }
    }

    private async Task ExecuteAsync(RemoteCommand command, RelayClient relay, DesktopPairing pairing, Uri relayUri, CancellationToken cancellationToken)
    {
        if (!_sessions.TryGetValue(StorageKey(command.SessionKey), out var owned)) throw new InvalidOperationException("The companion has not taken over this session");
        string? resolvedApproval = null;
        switch (command.Kind)
        {
            case "start":
                if (string.IsNullOrWhiteSpace(command.Text) || owned.ActiveTurnId is not null) throw new InvalidOperationException("This session cannot start a new turn");
                var started = await owned.Channel.CallAsync("turn/start", new { threadId = command.SessionKey.ThreadId, input = new[] { new { type = "text", text = command.Text, text_elements = Array.Empty<object>() } } }, cancellationToken);
                owned.ActiveTurnId = started.GetProperty("result").GetProperty("turn").GetProperty("id").GetString();
                owned.OwnsActiveTurn = owned.ActiveTurnId is not null;
                break;
            case "steer":
                if (!owned.OwnsActiveTurn || owned.ActiveTurnId is null || owned.ActiveTurnId != command.ExpectedTurnId || string.IsNullOrWhiteSpace(command.Text)) throw new InvalidOperationException("Active turn identity does not match or is not steerable");
                await owned.Channel.CallAsync("turn/steer", new { threadId = command.SessionKey.ThreadId, expectedTurnId = owned.ActiveTurnId, input = new[] { new { type = "text", text = command.Text, text_elements = Array.Empty<object>() } } }, cancellationToken);
                break;
            case "interrupt":
                if (!owned.OwnsActiveTurn || owned.ActiveTurnId is null || owned.ActiveTurnId != command.ExpectedTurnId) throw new InvalidOperationException("No matching turn to stop");
                await owned.Channel.CallAsync("turn/interrupt", new { threadId = command.SessionKey.ThreadId, turnId = owned.ActiveTurnId }, cancellationToken);
                break;
            case "approvalResponse":
                if (command.ApprovalRequestId is null || command.Approved is null || !owned.Approvals.TryRemove(command.ApprovalRequestId, out var pending)) throw new InvalidOperationException("Approval request is missing or already resolved");
                object result = pending.Method == "item/permissions/requestApproval"
                    ? new { permissions = command.Approved.Value ? (object)(pending.RequestedPermissions ?? EmptyObject()) : new { }, scope = "turn" }
                    : new { decision = command.Approved.Value ? "accept" : "decline" };
                await owned.Channel.SendAsync(new { id = pending.RpcId, result }, cancellationToken);
                resolvedApproval = command.ApprovalRequestId;
                break;
        }
        await relay.PublishRemoteEventAsync(relayUri, pairing, command.SessionKey, [], Capabilities(owned), resolvedApprovalRequestId: resolvedApproval, activeTurnId: owned.ActiveTurnId, cancellationToken: cancellationToken);
    }

    private async Task ConsumeAsync(JsonElement value, string storageKey, SessionKey key, Device device, RelayClient relay, DesktopPairing pairing, Uri relayUri, Func<UsageObservation, Task> onUsage, CancellationToken cancellationToken)
    {
        if (!_sessions.TryGetValue(storageKey, out var owned) || !value.TryGetProperty("method", out var methodNode) || methodNode.GetString() is not { } method) return;
        var parameters = value.TryGetProperty("params", out var paramsNode) ? paramsNode : EmptyObject();
        if (value.TryGetProperty("id", out var rpcId) && ApprovalMethods.Contains(method)) {
            var requestId = OpaqueId(rpcId);
            JsonElement? permissions = parameters.TryGetProperty("permissions", out var rawPermissions) ? rawPermissions.Clone() : null;
            owned.Approvals[requestId] = new(rpcId.Clone(), method, permissions);
            var approval = new RemoteApprovalRequest(requestId, key, method.Contains("fileChange") ? "fileChange" : method.Contains("permissions") ? "permissions" : "commandExecution", ApprovalTitle(method, parameters), ApprovalDetail(method, parameters), DateTimeOffset.UtcNow);
            await relay.PublishRemoteEventAsync(relayUri, pairing, key, [], Capabilities(owned), approval: approval, activeTurnId: owned.ActiveTurnId, cancellationToken: cancellationToken);
            return;
        }

        if (method == "thread/tokenUsage/updated" && TokenUsage(parameters) is { } usage)
            await onUsage(new(device.Id, device.Name, key.AccountFingerprint, key.ThreadId, DateTimeOffset.UtcNow, usage));

        string? resolved = null;
        if (method == "serverRequest/resolved" && parameters.TryGetProperty("requestId", out var resolvedNode)) {
            resolved = OpaqueId(resolvedNode); owned.Approvals.TryRemove(resolved, out _);
        }
        if (method == "turn/started" && parameters.TryGetProperty("turn", out var turn) && turn.TryGetProperty("id", out var turnId)) owned.ActiveTurnId = turnId.GetString();
        else if (method == "turn/completed") { owned.ActiveTurnId = null; owned.OwnsActiveTurn = false; }
        var item = StreamItem(method, parameters);
        if (item is null && resolved is null && method is not "turn/started" and not "turn/completed") return;
        await relay.PublishRemoteEventAsync(relayUri, pairing, key, item is null ? [] : [item], Capabilities(owned), resolvedApprovalRequestId: resolved, activeTurnId: owned.ActiveTurnId, cancellationToken: cancellationToken);
    }

    private async Task CloseAsync(SessionKey key)
    {
        OwnedSession? owned;
        await _gate.WaitAsync();
        try { _sessions.Remove(StorageKey(key), out owned); } finally { _gate.Release(); }
        if (owned is null) return;
        await owned.Channel.DisposeAsync();
        if (!owned.Process.HasExited) owned.Process.Kill(entireProcessTree: true);
        owned.Process.Dispose();
    }

    private static SessionCapabilities Capabilities(OwnedSession value) => new(true, true, true, value.ActiveTurnId is not null, value.OwnsActiveTurn && value.ActiveTurnId is not null, value.OwnsActiveTurn && value.ActiveTurnId is not null, true);
    private static string StorageKey(SessionKey key) => $"{key.DeviceId}:{key.AccountFingerprint}:{key.ThreadId}";
    private static string OpaqueId(JsonElement id) => id.ValueKind == JsonValueKind.String ? id.GetString()! : id.GetRawText();
    private static JsonElement EmptyObject() { using var document = JsonDocument.Parse("{}"); return document.RootElement.Clone(); }

    private static IReadOnlyList<RemoteStreamItem> TranscriptItems(JsonElement response)
    {
        var output = new List<RemoteStreamItem>();
        if (!response.GetProperty("result").TryGetProperty("thread", out var thread) || !thread.TryGetProperty("turns", out var turns) || turns.ValueKind != JsonValueKind.Array) return output;
        foreach (var turn in turns.EnumerateArray()) {
            if (!turn.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Array) continue;
            foreach (var item in items.EnumerateArray()) {
                var type = item.TryGetProperty("type", out var typeNode) ? typeNode.GetString() : null;
                var text = VisibleText(item);
                if (string.IsNullOrWhiteSpace(text) || type is not ("userMessage" or "agentMessage")) continue;
                var id = item.TryGetProperty("id", out var idNode) ? idNode.GetString() : Guid.NewGuid().ToString();
                output.Add(new($"history-{(type == "userMessage" ? "user" : "agent")}:{id}", type == "userMessage" ? "user" : "agent", text, "completed", DateTimeOffset.UtcNow));
            }
        }
        return output;
    }

    private static string VisibleText(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.String) return value.GetString() ?? "";
        if (value.ValueKind == JsonValueKind.Array) return string.Join("\n", value.EnumerateArray().Select(VisibleText).Where(x => !string.IsNullOrWhiteSpace(x)));
        if (value.ValueKind != JsonValueKind.Object) return "";
        if (value.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String) return text.GetString() ?? "";
        return value.TryGetProperty("content", out var content) ? VisibleText(content) : "";
    }

    private static string? ActiveTurnId(JsonElement response)
    {
        var thread = response.GetProperty("result").GetProperty("thread");
        if (!thread.TryGetProperty("status", out var status) || !status.TryGetProperty("type", out var type) || type.GetString() != "active" || !thread.TryGetProperty("turns", out var turns) || turns.GetArrayLength() == 0) return null;
        return turns[turns.GetArrayLength() - 1].TryGetProperty("id", out var id) ? id.GetString() : null;
    }

    private static TokenBreakdown? TokenUsage(JsonElement parameters)
    {
        if (!parameters.TryGetProperty("tokenUsage", out var usage) || !usage.TryGetProperty("total", out var total)) return null;
        long Number(string key) => total.TryGetProperty(key, out var value) && value.TryGetInt64(out var number) ? number : 0;
        return new(Number("inputTokens"), Number("cachedInputTokens"), Number("outputTokens"), Number("reasoningOutputTokens"), Number("totalTokens"));
    }

    private static RemoteStreamItem? StreamItem(string method, JsonElement parameters)
    {
        var now = DateTimeOffset.UtcNow;
        if (method == "item/agentMessage/delta") {
            var id = parameters.TryGetProperty("itemId", out var itemId) ? itemId.GetString() : Guid.NewGuid().ToString();
            var delta = parameters.TryGetProperty("delta", out var deltaNode) ? deltaNode.GetString() ?? "" : "";
            return new($"agent:{id}", "agent", delta, "running", now, true);
        }
        if (method == "turn/started") return new("turn-status", "status", "Codex is running", "running", now);
        if (method == "turn/completed") {
            var status = parameters.TryGetProperty("turn", out var turn) && turn.TryGetProperty("status", out var statusNode) ? statusNode.GetString() : "completed";
            return new("turn-status", "status", status == "interrupted" ? "Turn stopped" : status == "failed" ? "Turn failed" : "Turn completed", status == "interrupted" ? "interrupted" : status == "failed" ? "failed" : "completed", now);
        }
        if (method is "item/started" or "item/completed" && parameters.TryGetProperty("item", out var item)) {
            var completed = method == "item/completed";
            var type = item.TryGetProperty("type", out var typeNode) ? typeNode.GetString() : null;
            var id = item.TryGetProperty("id", out var idNode) ? idNode.GetString() : Guid.NewGuid().ToString();
            if (type == "commandExecution") {
                var command = item.TryGetProperty("command", out var commandNode) ? commandNode.GetString() : null;
                return new($"command:{id}", "command", command is null ? (completed ? "Command finished" : "Running a command") : (completed ? $"Finished: {command}" : $"Running: {command}"), completed ? "completed" : "running", now);
            }
            if (type == "fileChange") return new($"file:{id}", "fileChange", completed ? "File changes completed" : "Editing files", completed ? "completed" : "running", now);
        }
        if (method == "turn/diff/updated") return new(Guid.NewGuid().ToString(), "fileChange", "File changes updated", "running", now);
        if (method == "error") return new(Guid.NewGuid().ToString(), "error", parameters.TryGetProperty("error", out var error) && error.TryGetProperty("message", out var message) ? message.GetString() ?? "Codex error" : "Codex error", "failed", now);
        return null;
    }

    private static string ApprovalTitle(string method, JsonElement parameters) => parameters.TryGetProperty("networkApprovalContext", out _) ? "Network-access approval required" : method.Contains("fileChange") ? "File-change approval required" : method.Contains("permissions") ? "Permission approval required" : "Command execution approval required";
    private static string ApprovalDetail(string method, JsonElement parameters)
    {
        var rows = new List<string>();
        foreach (var key in new[] { "reason", "command", "cwd", "grantRoot" }) if (parameters.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString())) rows.Add(value.GetString()!);
        return rows.Count == 0 ? (method.Contains("permissions") ? "Codex is requesting extra sandbox permission" : "Codex is waiting for your decision") : string.Join("\n", rows);
    }
}

internal sealed class JsonRpcChannel : IAsyncDisposable
{
    private readonly Process _process;
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _pending = new();
    private readonly SemaphoreSlim _writer = new(1, 1);
    private Func<JsonElement, Task>? _handler;
    private Task? _reader;
    private int _nextId;

    public JsonRpcChannel(Process process) { _process = process; }
    public void Start(Func<JsonElement, Task> handler) { _handler = handler; _reader = Task.Run(ReadLoopAsync); }
    public async Task<JsonElement> CallAsync(string method, object parameters, CancellationToken cancellationToken)
    {
        var id = Interlocked.Increment(ref _nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = completion;
        await SendAsync(new { method, id, @params = parameters }, cancellationToken);
        using var registration = cancellationToken.Register(() => completion.TrySetCanceled(cancellationToken));
        return await completion.Task;
    }
    public async Task SendAsync(object value, CancellationToken cancellationToken)
    {
        await _writer.WaitAsync(cancellationToken);
        try { await _process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(value).AsMemory(), cancellationToken); await _process.StandardInput.FlushAsync(cancellationToken); }
        finally { _writer.Release(); }
    }
    private async Task ReadLoopAsync()
    {
        Exception? terminal = null;
        try {
            while (await _process.StandardOutput.ReadLineAsync() is { } line) {
                using var document = JsonDocument.Parse(line); var root = document.RootElement.Clone();
                if (!root.TryGetProperty("method", out _) && root.TryGetProperty("id", out var idNode) && idNode.TryGetInt32(out var id) && _pending.TryRemove(id, out var completion)) {
                    if (root.TryGetProperty("error", out var error)) completion.TrySetException(new InvalidOperationException(error.TryGetProperty("message", out var message) ? message.GetString() : "App Server request failed"));
                    else completion.TrySetResult(root);
                } else if (_handler is not null) await _handler(root);
            }
            terminal = new InvalidOperationException("Codex App Server closed");
        } catch (Exception error) { terminal = error; }
        foreach (var completion in _pending.Values) completion.TrySetException(terminal);
        _pending.Clear();
    }
    public async ValueTask DisposeAsync()
    {
        try { _process.StandardInput.Close(); } catch { }
        if (_reader is not null) { try { await _reader.WaitAsync(TimeSpan.FromSeconds(1)); } catch { } }
        foreach (var completion in _pending.Values) completion.TrySetCanceled();
    }
}
