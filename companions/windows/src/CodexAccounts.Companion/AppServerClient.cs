using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexAccounts.Companion;

public sealed class AppServerClient
{
    private int _nextId;
    public async Task<ProfileObservation> ObserveAsync(LocalProfile profile, string deviceId, CancellationToken cancellationToken = default)
    {
        var start = new ProcessStartInfo(profile.CodexBinary, "app-server") { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        if (!string.IsNullOrWhiteSpace(profile.CodexHome)) start.Environment["CODEX_HOME"] = profile.CodexHome;
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Unable to start Codex CLI");
        try
        {
            await CallAsync(process, "initialize", new { clientInfo = new { name = "quota_pool_companion", title = "Quota Pool Companion", version = "1.1.0" } }, cancellationToken);
            await SendAsync(process, new { method = "initialized", @params = new { } });
            var accountResult = await CallAsync(process, "account/read", new { refreshToken = false }, cancellationToken);
            var accountNode = accountResult.GetProperty("result").GetProperty("account");
            if (accountNode.ValueKind != JsonValueKind.Object || accountNode.GetProperty("type").GetString() != "chatgpt") throw new InvalidOperationException("This local profile is not signed in to ChatGPT");
            var email = accountNode.TryGetProperty("email", out var emailNode) ? emailNode.GetString() ?? "unknown@local" : "unknown@local";
            var plan = accountNode.TryGetProperty("planType", out var planNode) ? planNode.GetString() ?? "unknown" : "unknown";
            var accountId = StableAccountId(email);
            var account = new Account(accountId, email, string.IsNullOrWhiteSpace(profile.Alias) ? null : profile.Alias, plan, null);
            var limits = await CallAsync(process, "account/rateLimits/read", new { }, cancellationToken);
            var observedAt = DateTimeOffset.UtcNow;
            var (windows, credits) = ParseLimits(limits.GetProperty("result"), accountId, observedAt);
            var threads = await CallAsync(process, "thread/list", new { limit = 50, sortKey = "updated_at", sortDirection = "desc" }, cancellationToken);
            var sessions = ParseSessions(threads.GetProperty("result"), deviceId, Environment.MachineName, account);
            return new(account, new(deviceId, accountId, profile.IsCurrent, profile.Id.ToString(), observedAt), windows, credits, sessions);
        }
        finally { if (!process.HasExited) process.Kill(entireProcessTree: true); }
    }

    private async Task<JsonElement> CallAsync(Process process, string method, object parameters, CancellationToken cancellationToken)
    {
        var id = Interlocked.Increment(ref _nextId);
        await SendAsync(process, new { method, id, @params = parameters });
        while (true)
        {
            var line = await process.StandardOutput.ReadLineAsync(cancellationToken) ?? throw new InvalidOperationException("Codex App Server closed");
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.TryGetProperty("id", out var responseId) && responseId.GetInt32() == id)
            {
                if (root.TryGetProperty("error", out var error)) throw new InvalidOperationException(error.TryGetProperty("message", out var message) ? message.GetString() : method);
                return root.Clone();
            }
        }
    }
    private static Task SendAsync(Process process, object value) => process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(value));

    private static (IReadOnlyList<RateLimitWindow>, ResetCreditSummary) ParseLimits(JsonElement result, string accountId, DateTimeOffset observedAt)
    {
        var buckets = new List<JsonElement>();
        if (result.TryGetProperty("rateLimitsByLimitId", out var byId) && byId.ValueKind == JsonValueKind.Object) buckets.AddRange(byId.EnumerateObject().Select(x => x.Value));
        else if (result.TryGetProperty("rateLimits", out var single) && single.ValueKind == JsonValueKind.Object) buckets.Add(single);
        var windows = new List<RateLimitWindow>();
        foreach (var bucket in buckets)
        {
            var limitId = bucket.TryGetProperty("limitId", out var id) ? id.GetString() : null;
            foreach (var name in new[] { "primary", "secondary" })
            {
                if (!bucket.TryGetProperty(name, out var window) || window.ValueKind != JsonValueKind.Object) continue;
                var duration = window.GetProperty("windowDurationMins").GetInt32();
                windows.Add(new($"{accountId}:{limitId ?? "default"}:{duration}", accountId, limitId, duration, window.GetProperty("usedPercent").GetDouble(), DateTimeOffset.FromUnixTimeSeconds(window.GetProperty("resetsAt").GetInt64()), observedAt));
            }
        }
        if (!result.TryGetProperty("rateLimitResetCredits", out var raw) || raw.ValueKind != JsonValueKind.Object) return (windows, new(accountId, 0, null));
        var count = raw.GetProperty("availableCount").GetInt32();
        List<ResetCredit>? credits = null;
        if (raw.TryGetProperty("credits", out var rows) && rows.ValueKind == JsonValueKind.Array)
        {
            credits = rows.EnumerateArray().Select(item => new ResetCredit(item.GetProperty("id").GetString()!, accountId, item.TryGetProperty("title", out var title) && title.ValueKind == JsonValueKind.String ? title.GetString() : null, item.GetProperty("resetType").GetString()!, item.GetProperty("status").GetString()!, DateTimeOffset.FromUnixTimeSeconds(item.GetProperty("grantedAt").GetInt64()), item.TryGetProperty("expiresAt", out var expires) && expires.ValueKind == JsonValueKind.Number ? DateTimeOffset.FromUnixTimeSeconds(expires.GetInt64()) : null)).ToList();
        }
        return (windows, new(accountId, count, credits));
    }

    private static IReadOnlyList<SessionSummary> ParseSessions(JsonElement result, string deviceId, string deviceName, Account account)
    {
        if (!result.TryGetProperty("data", out var rows) || rows.ValueKind != JsonValueKind.Array) return [];
        var sessions = new List<SessionSummary>();
        foreach (var thread in rows.EnumerateArray())
        {
            if (!thread.TryGetProperty("id", out var idNode) || idNode.GetString() is not { } threadId) continue;
            var preview = thread.TryGetProperty("preview", out var previewNode) && previewNode.ValueKind == JsonValueKind.String ? previewNode.GetString()?.Trim() ?? "" : "";
            var title = thread.TryGetProperty("name", out var nameNode) && nameNode.ValueKind == JsonValueKind.String ? nameNode.GetString()?.Trim() : null;
            var runtime = "notLoaded";
            if (thread.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.Object && status.TryGetProperty("type", out var typeNode)) runtime = typeNode.GetString() ?? runtime;
            long updated = 0;
            if (thread.TryGetProperty("recencyAt", out var recencyNode) && recencyNode.ValueKind == JsonValueKind.Number) updated = recencyNode.GetInt64();
            else if (thread.TryGetProperty("updatedAt", out var updatedNode) && updatedNode.ValueKind == JsonValueKind.Number) updated = updatedNode.GetInt64();
            var model = thread.TryGetProperty("modelProvider", out var modelNode) && modelNode.ValueKind == JsonValueKind.String ? modelNode.GetString() : null;
            sessions.Add(new(
                new(deviceId, account.Id, threadId),
                string.IsNullOrWhiteSpace(title) ? (string.IsNullOrWhiteSpace(preview) ? "Untitled session" : preview) : title,
                preview, deviceName, account.Alias ?? account.Email, account.PlanType, runtime, model, null, null,
                DateTimeOffset.FromUnixTimeSeconds(updated),
                new(Readable: true, Active: runtime == "active")
            ));
        }
        return sessions;
    }
    private static string StableAccountId(string email) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(email.ToLowerInvariant()))).ToLowerInvariant();
}
