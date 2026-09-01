using System.Text.Json.Serialization;

namespace CodexAccounts.Companion;

public sealed record Device(string Id, string Name, string Platform, string OsVersion, string CodexVersion, string OnlineState, DateTimeOffset LastSeenAt);
public sealed record Account(string Id, string Email, string? Alias, string PlanType, DateTimeOffset? RenewalAt);
public sealed record AccountPresence(string DeviceId, string AccountId, bool IsCurrent, string ProfileKey, DateTimeOffset LastSeenAt);
public sealed record RateLimitWindow(string Id, string AccountId, string? LimitId, int DurationMins, double UsedPercent, DateTimeOffset ResetsAt, DateTimeOffset ObservedAt)
{
    [JsonIgnore] public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
}
public sealed record ResetCredit(string Id, string AccountId, string? Title, string ResetType, string Status, DateTimeOffset GrantedAt, DateTimeOffset? ExpiresAt);
public sealed record ResetCreditSummary(string AccountId, int AvailableCount, IReadOnlyList<ResetCredit>? Credits);
public sealed record GlobalRateLimitReset(string Id, DateTimeOffset OccurredAt, string Source, string? Note);
public sealed record ActivityEvent(string Id, string DeviceId, string? AccountId, string Type, DateTimeOffset OccurredAt, Dictionary<string, string> Payload);
public sealed record SessionKey(string DeviceId, string AccountFingerprint, string ThreadId);
public sealed record SessionCapabilities(bool Readable = true, bool Resumable = false, bool Writable = false, bool Active = false, bool Steerable = false, bool Interruptible = false, bool ApprovalCapable = false);
public sealed record SessionSummary(SessionKey Key, string Title, string Preview, string DeviceName, string AccountAlias, string PlanType, string RuntimeState, string? Model, string? ReasoningEffort, string? ActiveTurnId, DateTimeOffset UpdatedAt, SessionCapabilities Capabilities)
{
    [JsonIgnore] public string Id => $"{Key.DeviceId}:{Key.AccountFingerprint}:{Key.ThreadId}";
}
public sealed record TokenBreakdown(long InputTokens = 0, long CachedInputTokens = 0, long OutputTokens = 0, long ReasoningTokens = 0, long TotalTokens = 0);
public sealed record DeviceUsageDay(DateTimeOffset Date, string DeviceId, string DeviceName, TokenBreakdown Tokens);
public sealed record TiboAnnouncement(string Id, DateTimeOffset ObservedAt, string SourceName, string Summary, DateTimeOffset? ExpectedResetAt = null);
public sealed record RemoteStreamItem(string Id, string Kind, string Text, string State, DateTimeOffset CreatedAt, bool? Append = null);
public sealed record RemoteApprovalRequest(string Id, SessionKey SessionKey, string Kind, string Title, string Detail, DateTimeOffset CreatedAt);
public sealed record RemoteCommand(string Id, string Kind, SessionKey SessionKey, string? ExpectedTurnId, string? Text, string? ApprovalRequestId, bool? Approved, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt);
public sealed record UsageObservation(string DeviceId, string DeviceName, string AccountFingerprint, string ThreadId, DateTimeOffset ObservedAt, TokenBreakdown Cumulative)
{
    [JsonIgnore] public string Key => $"{DeviceId}:{AccountFingerprint}:{ThreadId}";
}
public sealed record Snapshot(
    int SchemaVersion,
    Device Device,
    IReadOnlyList<Account> Accounts,
    IReadOnlyList<AccountPresence> Presences,
    IReadOnlyList<RateLimitWindow> RateLimitWindows,
    IReadOnlyList<ResetCreditSummary> ResetCreditSummaries,
    IReadOnlyList<GlobalRateLimitReset> GlobalRateLimitResets,
    IReadOnlyList<ActivityEvent> Activity,
    DateTimeOffset ObservedAt,
    IReadOnlyList<SessionSummary>? SessionSummaries = null,
    IReadOnlyList<DeviceUsageDay>? DeviceUsageDays = null,
    TiboAnnouncement? TiboAnnouncement = null);

public sealed class LocalProfile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Alias { get; set; } = "New account";
    public string CodexHome { get; set; } = "";
    public string CodexBinary { get; set; } = "codex";
    public bool IsCurrent { get; set; }
}
public sealed record ProfileObservation(Account Account, AccountPresence Presence, IReadOnlyList<RateLimitWindow> Windows, ResetCreditSummary Credits, IReadOnlyList<SessionSummary> Sessions);
public sealed record DesktopPairing(string DeviceId, string ProtectedToken, string ProtectedKey);
public sealed record EncryptedEnvelope(int Version, string Nonce, string Ciphertext, string Tag, DateTimeOffset ObservedAt);
