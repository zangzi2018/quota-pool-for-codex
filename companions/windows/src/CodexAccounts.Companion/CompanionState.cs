using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace CodexAccounts.Companion;

public sealed class CompanionState : INotifyPropertyChanged
{
    private readonly string _path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexAccounts", "companion.json");
    private readonly AppServerClient _appServer = new();
    private readonly RelayClient _relay = new();
    private readonly RemoteSessionRuntime _remote = new();
    private string _relayUrl = "http://127.0.0.1:8787", _pairingCode = "", _status = "Not synced yet";
    private bool _isWorking;
    private string _pairingFingerprint = "";
    private readonly string _deviceId;
    private Snapshot? _lastSnapshot;
    private readonly List<GlobalRateLimitReset> _globalResets;
    private readonly Dictionary<string, UsageObservation> _latestUsage;
    private readonly List<DeviceUsageDay> _usageDays;
    private readonly HashSet<string> _processedCommandIds = [];
    public event PropertyChangedEventHandler? PropertyChanged;
    public ObservableCollection<LocalProfile> Profiles { get; } = [];
    public DesktopPairing? Pairing { get; private set; }
    public string RelayUrl { get => _relayUrl; set => Set(ref _relayUrl, value); }
    public string PairingCode { get => _pairingCode; set => Set(ref _pairingCode, value); }
    public string Status { get => _status; private set => Set(ref _status, value); }
    public bool IsWorking { get => _isWorking; private set => Set(ref _isWorking, value); }
    public string PairingFingerprint { get => _pairingFingerprint; private set => Set(ref _pairingFingerprint, value); }
    public string DeviceName => Environment.MachineName;
    public string PairingState => Pairing is null ? "Not connected" : "Connected";

    public CompanionState()
    {
        var saved = Load(); _deviceId = saved?.DeviceId ?? Guid.NewGuid().ToString(); _lastSnapshot = saved?.LastSnapshot; _globalResets = saved?.GlobalResets ?? []; _latestUsage = saved?.LatestUsage ?? []; _usageDays = saved?.UsageDays ?? []; RelayUrl = saved?.RelayUrl ?? RelayUrl; Pairing = saved?.Pairing;
        foreach (var profile in saved?.Profiles ?? [new LocalProfile { Alias = "My account", IsCurrent = true }]) Profiles.Add(profile);
    }
    public void AddProfile() => Profiles.Add(new LocalProfile());
    public void RemoveProfile(LocalProfile? profile) { if (profile is not null) Profiles.Remove(profile); }
    public void Save()
    {
        NormalizeCurrentProfile();
        var parsed = RelayUrlPolicy.Parse(RelayUrl);
        RelayUrl = parsed.Url.AbsoluteUri;
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, JsonSerializer.Serialize(new SavedState(RelayUrl, Profiles.ToList(), Pairing, _deviceId, _lastSnapshot, _globalResets, _latestUsage, _usageDays), JsonOptions));
        Status = parsed.UsesCleartext ? "Saved. LAN cleartext relay; use HTTPS on the public internet." : "Settings saved";
    }
    public async Task PairAsync()
    {
        var code = new string(PairingCode.Where(char.IsDigit).ToArray());
        if (code.Length != 6) throw new InvalidOperationException("Enter a 6-digit pairing code");
        var relay = RelayUrlPolicy.Parse(RelayUrl).Url;
        IsWorking = true; Status = "Waiting for iPhone confirmation";
        try { Pairing = await _relay.PairAsync(relay, code, Device(), fingerprint => { PairingFingerprint = "Fingerprint  " + fingerprint; Status = "Confirm the security fingerprint on iPhone"; }); Save(); Status = "Paired"; Raise(nameof(PairingState)); await SyncAsync(); }
        finally { IsWorking = false; }
    }
    public async Task SyncAsync()
    {
        if (Pairing is null) throw new InvalidOperationException("Connect iPhone first");
        NormalizeCurrentProfile();
        IsWorking = true; Status = "Reading local Codex";
        try
        {
            var observations = new List<ProfileObservation>();
            foreach (var profile in Profiles) observations.Add(await _appServer.ObserveAsync(profile, Pairing.DeviceId));
            var now = DateTimeOffset.UtcNow; var device = Device();
            var accounts = observations.Select(x => x.Account).GroupBy(x => x.Id).Select(x => x.First()).ToList();
            var presences = observations.Select(x => x.Presence).GroupBy(x => x.AccountId).Select(x => x.OrderByDescending(p => p.IsCurrent).ThenByDescending(p => p.LastSeenAt).First()).ToList();
            var windows = observations.SelectMany(x => x.Windows).GroupBy(x => x.Id).Select(x => x.OrderByDescending(w => w.ObservedAt).First()).ToList();
            var summaries = observations.Select(x => x.Credits).GroupBy(x => x.AccountId).Select(group => { var rows = group.SelectMany(x => x.Credits ?? []).GroupBy(x => x.Id).Select(x => x.First()).ToList(); return new ResetCreditSummary(group.Key, group.Max(x => x.AvailableCount), group.All(x => x.Credits is null) ? null : rows); }).ToList();
            var sessions = observations.SelectMany(x => x.Sessions).GroupBy(x => x.Id).Select(x => x.OrderByDescending(row => row.UpdatedAt).First()).ToList();
            var activity = BuildActivity(_lastSnapshot, accounts, presences, windows, summaries, device, now);
            var snapshot = new Snapshot(1, device, accounts, presences, windows, summaries, _globalResets, activity, now, sessions, _usageDays);
            await _relay.UploadAsync(RelayUrlPolicy.Parse(RelayUrl).Url, Pairing, snapshot); _lastSnapshot = snapshot; Save(); Status = $"Synced {snapshot.Accounts.Count} accounts";
        }
        finally { IsWorking = false; }
    }
    public async Task RunRelayConnectionAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                if (Pairing is null) { await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken); continue; }
                await _relay.RunConnectionAsync(RelayUrlPolicy.Parse(RelayUrl).Url, Pairing, command => HandleRemoteCommandAsync(command, cancellationToken), cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
            catch { await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken); }
        }
    }
    private async Task HandleRemoteCommandAsync(RemoteCommand command, CancellationToken cancellationToken)
    {
        if (Pairing is null || !_processedCommandIds.Add(command.Id)) return;
        var relay = RelayUrlPolicy.Parse(RelayUrl).Url;
        try { await _remote.HandleAsync(command, Profiles.ToList(), Device(), _relay, Pairing, relay, RecordUsageAsync, cancellationToken); }
        catch (Exception error) {
            await _relay.PublishRemoteEventAsync(relay, Pairing, command.SessionKey, [new(Guid.NewGuid().ToString(), "error", error.Message, "failed", DateTimeOffset.UtcNow)], null, cancellationToken: cancellationToken);
        }
        try { await _relay.AcknowledgeCommandAsync(relay, Pairing, command.Id, cancellationToken); } catch { }
    }
    private async Task RecordUsageAsync(UsageObservation observation)
    {
        if (!_latestUsage.TryGetValue(observation.Key, out var previous)) { _latestUsage[observation.Key] = observation; Save(); return; }
        _latestUsage[observation.Key] = observation;
        var delta = new TokenBreakdown(
            Math.Max(0, observation.Cumulative.InputTokens - previous.Cumulative.InputTokens),
            Math.Max(0, observation.Cumulative.CachedInputTokens - previous.Cumulative.CachedInputTokens),
            Math.Max(0, observation.Cumulative.OutputTokens - previous.Cumulative.OutputTokens),
            Math.Max(0, observation.Cumulative.ReasoningTokens - previous.Cumulative.ReasoningTokens),
            Math.Max(0, observation.Cumulative.TotalTokens - previous.Cumulative.TotalTokens));
        if (delta.TotalTokens > 0) {
            var day = new DateTimeOffset(observation.ObservedAt.UtcDateTime.Date, TimeSpan.Zero);
            var index = _usageDays.FindIndex(x => x.DeviceId == observation.DeviceId && x.Date == day);
            if (index >= 0) {
                var old = _usageDays[index];
                _usageDays[index] = old with { Tokens = new(old.Tokens.InputTokens + delta.InputTokens, old.Tokens.CachedInputTokens + delta.CachedInputTokens, old.Tokens.OutputTokens + delta.OutputTokens, old.Tokens.ReasoningTokens + delta.ReasoningTokens, old.Tokens.TotalTokens + delta.TotalTokens) };
            } else _usageDays.Add(new(day, observation.DeviceId, observation.DeviceName, delta));
            if (_lastSnapshot is not null && Pairing is not null) {
                _lastSnapshot = _lastSnapshot with { DeviceUsageDays = _usageDays, ObservedAt = DateTimeOffset.UtcNow, Device = Device() };
                try { await _relay.UploadAsync(RelayUrlPolicy.Parse(RelayUrl).Url, Pairing, _lastSnapshot); } catch { }
            }
        }
        Save();
    }
    private Device Device() => new(_deviceId, DeviceName, "windows", Environment.OSVersion.VersionString, "Activity", "online", DateTimeOffset.UtcNow);
    public void RecordVerifiedGlobalReset() { _globalResets.Insert(0, new(Guid.NewGuid().ToString(), DateTimeOffset.UtcNow, "official", "Confirmed on desktop: applied to all users at the same time")); if (_globalResets.Count > 100) _globalResets.RemoveRange(100, _globalResets.Count - 100); Save(); }
    private void NormalizeCurrentProfile() { if (Profiles.Count == 0) return; var selected = Profiles.Select((profile, index) => (profile, index)).FirstOrDefault(x => x.profile.IsCurrent).index; for (var index = 0; index < Profiles.Count; index++) Profiles[index].IsCurrent = index == selected; }
    private SavedState? Load() { try { return File.Exists(_path) ? JsonSerializer.Deserialize<SavedState>(File.ReadAllText(_path), JsonOptions) : null; } catch { return null; } }
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null) { if (EqualityComparer<T>.Default.Equals(field, value)) return; field = value; Raise(name); }
    private void Raise(string? name) => PropertyChanged?.Invoke(this, new(name));
    private static IReadOnlyList<ActivityEvent> BuildActivity(Snapshot? previous, IReadOnlyList<Account> accounts, IReadOnlyList<AccountPresence> presences, IReadOnlyList<RateLimitWindow> windows, IReadOnlyList<ResetCreditSummary> summaries, Device device, DateTimeOffset now)
    {
        var events = new List<ActivityEvent>(); var names = accounts.ToDictionary(x => x.Id, x => x.Alias ?? x.Email);
        void Add(string type, string? accountId, string title, string detail) => events.Add(new(Guid.NewGuid().ToString(), device.Id, accountId, type, now, new() { ["title"] = title, ["detail"] = detail }));
        if (previous is not null)
        {
            var oldCurrent = previous.Presences.FirstOrDefault(x => x.IsCurrent)?.AccountId; var newCurrent = presences.FirstOrDefault(x => x.IsCurrent)?.AccountId;
            if (oldCurrent != newCurrent && newCurrent is not null) Add("activeAccountChanged", newCurrent, "Current account changed", $"{(oldCurrent is not null && names.TryGetValue(oldCurrent, out var oldName) ? oldName : "Unknown account")} → {names.GetValueOrDefault(newCurrent, "Unknown account")}");
            var oldWindows = previous.RateLimitWindows.ToDictionary(x => x.Id); var newWindows = windows.ToDictionary(x => x.Id);
            foreach (var quota in windows) { var label = QuotaName(quota.DurationMins); if (oldWindows.TryGetValue(quota.Id, out var old) && Math.Abs(old.UsedPercent - quota.UsedPercent) >= .5) Add("quotaChanged", quota.AccountId, $"{label} changed", $"Remaining {old.RemainingPercent:F0}% → {quota.RemainingPercent:F0}%"); else if (!oldWindows.ContainsKey(quota.Id)) Add("quotaRefreshed", quota.AccountId, "Quota refreshed", $"{names.GetValueOrDefault(quota.AccountId, "Account")} {label} refreshed"); }
            foreach (var quota in previous.RateLimitWindows.Where(x => !newWindows.ContainsKey(x.Id))) Add("quotaReset", quota.AccountId, "Quota reset", $"{names.GetValueOrDefault(quota.AccountId, "Account")} {QuotaName(quota.DurationMins)} reset");
            var oldCredits = previous.ResetCreditSummaries.SelectMany(x => x.Credits ?? []).ToDictionary(x => x.Id); var newCredits = summaries.SelectMany(x => x.Credits ?? []).ToDictionary(x => x.Id);
            foreach (var credit in newCredits.Values.Where(x => !oldCredits.ContainsKey(x.Id))) Add("resetAdded", credit.AccountId, "Saved rate-limit reset added", names.GetValueOrDefault(credit.AccountId, "Accounts"));
            foreach (var credit in oldCredits.Values.Where(x => !newCredits.ContainsKey(x.Id))) Add("resetExpired", credit.AccountId, "Saved rate-limit reset expired", names.GetValueOrDefault(credit.AccountId, "Accounts"));
        }
        Add("deviceSynced", null, "Device synced", device.Name);
        return events.Concat(previous?.Activity ?? []).OrderByDescending(x => x.OccurredAt).Take(200).ToList();
    }
    private static string QuotaName(int minutes) => minutes switch { 300 => "5-hour quota", 10080 => "Weekly quota", _ when minutes % 1440 == 0 => $"{minutes / 1440}-day quota", _ when minutes % 60 == 0 => $"{minutes / 60}-hour quota", _ => $"{minutes}-minute quota" };
    private sealed record SavedState(string RelayUrl, List<LocalProfile> Profiles, DesktopPairing? Pairing, string? DeviceId = null, Snapshot? LastSnapshot = null, List<GlobalRateLimitReset>? GlobalResets = null, Dictionary<string, UsageObservation>? LatestUsage = null, List<DeviceUsageDay>? UsageDays = null);
}
