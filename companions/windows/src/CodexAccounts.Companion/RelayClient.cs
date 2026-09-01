using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexAccounts.Companion;

public sealed class RelayClient
{
    private readonly HttpClient _client;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private sealed record PairingRecord(string Id, string? PhonePublicKey, string State, string? DeviceToken, string? PhoneProof);

    public RelayClient(HttpClient? client = null)
    {
        if (client is not null) { _client = client; return; }
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.None,
            SslOptions = { EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13 }
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
    }

    public async Task<DesktopPairing> PairAsync(Uri relay, string code, Device device, Action<string>? onFingerprint = null, CancellationToken cancellationToken = default)
    {
        relay = RelayUrlPolicy.Parse(relay.AbsoluteUri).Url;
        var waiting = await Get<PairingRecord>(relay, $"/v1/pairings/{code}", null, cancellationToken);
        if (string.IsNullOrEmpty(waiting.PhonePublicKey)) throw new InvalidOperationException("Invalid phone public key");
        using var desktop = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        using var phone = ImportX963(waiting.PhonePublicKey);
        var prk = desktop.DeriveKeyFromHmac(phone.PublicKey, HashAlgorithmName.SHA256, Encoding.UTF8.GetBytes("CodexAccounts/v1"), null, null);
        var key = HkdfExpand(prk, 32);
        onFingerprint?.Invoke(string.Join("-", SHA256.HashData(key).Take(6).Select(x => x.ToString("X2"))));
        var proof = Convert.ToBase64String(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes($"desktop-claim:{waiting.Id}")));
        var claim = new { desktopPublicKey = ExportX963(desktop), desktopProof = proof, device };
        await Put<PairingRecord>(relay, $"/v1/pairings/{code}/claim", claim, null, cancellationToken);
        while (true)
        {
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            var status = await Get<PairingRecord>(relay, $"/v1/pairings/{waiting.Id}/status", null, cancellationToken, new Dictionary<string, string> { ["X-Desktop-Proof"] = proof });
            if (status.State == "confirmed" && status.DeviceToken is { } token && status.PhoneProof is { } phoneProof)
            {
                var expected = Convert.ToBase64String(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes($"phone-confirm:{waiting.Id}")));
                if (!CryptographicOperations.FixedTimeEquals(Convert.FromBase64String(phoneProof), Convert.FromBase64String(expected))) throw new InvalidOperationException("Invalid iPhone pairing proof");
                var protectedKey = Convert.ToBase64String(ProtectedData.Protect(key, null, DataProtectionScope.CurrentUser));
                var protectedToken = Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(token), null, DataProtectionScope.CurrentUser));
                return new(device.Id, protectedToken, protectedKey);
            }
        }
    }

    public async Task UploadAsync(Uri relay, DesktopPairing pairing, Snapshot snapshot, CancellationToken cancellationToken = default)
    {
        var key = ProtectedData.Unprotect(Convert.FromBase64String(pairing.ProtectedKey), null, DataProtectionScope.CurrentUser);
        var token = Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(pairing.ProtectedToken), null, DataProtectionScope.CurrentUser));
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(snapshot, Json);
        var nonce = RandomNumberGenerator.GetBytes(12); var ciphertext = new byte[plaintext.Length]; var tag = new byte[16];
        using (var aes = new AesGcm(key, 16)) aes.Encrypt(nonce, plaintext, ciphertext, tag);
        var envelope = new EncryptedEnvelope(1, Convert.ToBase64String(nonce), Convert.ToBase64String(ciphertext), Convert.ToBase64String(tag), snapshot.ObservedAt);
        await Put<object>(relay, $"/v1/devices/{pairing.DeviceId}/snapshot", envelope, token, cancellationToken);
    }

    public async Task RunConnectionAsync(Uri relay, DesktopPairing pairing, Func<RemoteCommand, Task> onCommand, CancellationToken cancellationToken = default)
    {
        var token = DeviceToken(pairing);
        relay = RelayUrlPolicy.Parse(relay.AbsoluteUri).Url;
        var builder = new UriBuilder(relay) { Scheme = relay.Scheme == "https" ? "wss" : "ws", Path = $"/v1/devices/{pairing.DeviceId}/stream", Query = "role=companion" };
        using var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("Authorization", $"Bearer {token}");
        await socket.ConnectAsync(builder.Uri, cancellationToken);
        var heartbeat = Task.Run(async () => {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(20));
            do {
                var payload = Encoding.UTF8.GetBytes("{\"type\":\"heartbeat\"}");
                await socket.SendAsync(payload, WebSocketMessageType.Text, true, cancellationToken);
            } while (await timer.WaitForNextTickAsync(cancellationToken) && socket.State == WebSocketState.Open);
        }, cancellationToken);
        var receiveBuffer = new byte[16 * 1024];
        try {
            while (!cancellationToken.IsCancellationRequested && socket.State == WebSocketState.Open) {
                using var message = new MemoryStream();
                WebSocketReceiveResult result;
                do {
                    result = await socket.ReceiveAsync(receiveBuffer, cancellationToken);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    message.Write(receiveBuffer, 0, result.Count);
                } while (!result.EndOfMessage);
                if (result.MessageType != WebSocketMessageType.Text) continue;
                var pushed = JsonSerializer.Deserialize<PushedCommand>(message.ToArray(), Json);
                if (pushed is { Type: "command" }) await onCommand(Decrypt<RemoteCommand>(pushed.Command.Envelope, DeviceKey(pairing)));
            }
        } finally {
            try { await heartbeat; } catch (OperationCanceledException) { }
        }
    }

    public Task PublishRemoteEventAsync(Uri relay, DesktopPairing pairing, SessionKey key, IReadOnlyList<RemoteStreamItem> items, SessionCapabilities? capabilities, RemoteApprovalRequest? approval = null, string? resolvedApprovalRequestId = null, string? activeTurnId = null, CancellationToken cancellationToken = default)
    {
        var envelope = Encrypt(new EventPayload(items, capabilities, approval, resolvedApprovalRequestId, activeTurnId), DeviceKey(pairing));
        return Post(relay, $"/v1/devices/{pairing.DeviceId}/events", new { accountFingerprint = key.AccountFingerprint, threadId = key.ThreadId, envelope }, DeviceToken(pairing), cancellationToken);
    }

    public Task AcknowledgeCommandAsync(Uri relay, DesktopPairing pairing, string commandId, CancellationToken cancellationToken = default)
        => Post(relay, $"/v1/devices/{pairing.DeviceId}/commands/{commandId}/ack", new { }, DeviceToken(pairing), cancellationToken);

    private async Task<T> Get<T>(Uri relay, string path, string? token, CancellationToken ct, IDictionary<string, string>? headers = null)
    {
        using var request = Message(HttpMethod.Get, relay, path, token, null, headers);
        using var response = await _client.SendAsync(request, ct); await Ensure(response, ct); return (await response.Content.ReadFromJsonAsync<T>(Json, ct))!;
    }
    private async Task<T?> Put<T>(Uri relay, string path, object value, string? token, CancellationToken ct)
    {
        using var request = Message(HttpMethod.Put, relay, path, token, value);
        using var response = await _client.SendAsync(request, ct); await Ensure(response, ct); if (response.StatusCode == System.Net.HttpStatusCode.NoContent) return default; return await response.Content.ReadFromJsonAsync<T>(Json, ct);
    }
    private async Task Post(Uri relay, string path, object value, string? token, CancellationToken ct)
    {
        using var request = Message(HttpMethod.Post, relay, path, token, value);
        using var response = await _client.SendAsync(request, ct); await Ensure(response, ct);
    }
    private static HttpRequestMessage Message(HttpMethod method, Uri relay, string path, string? token, object? value, IDictionary<string, string>? headers = null)
    {
        var safe = RelayUrlPolicy.Parse(relay.AbsoluteUri).Url;
        var request = new HttpRequestMessage(method, new Uri(safe, path));
        if (token is not null) request.Headers.Authorization = new("Bearer", token);
        if (headers is not null) foreach (var pair in headers) request.Headers.TryAddWithoutValidation(pair.Key, pair.Value);
        if (value is not null) request.Content = JsonContent.Create(value, options: Json);
        return request;
    }
    private static string DeviceToken(DesktopPairing pairing) => Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(pairing.ProtectedToken), null, DataProtectionScope.CurrentUser));
    private static byte[] DeviceKey(DesktopPairing pairing) => ProtectedData.Unprotect(Convert.FromBase64String(pairing.ProtectedKey), null, DataProtectionScope.CurrentUser);
    private static EncryptedEnvelope Encrypt(object value, byte[] key)
    {
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(value, Json);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(key, 16)) aes.Encrypt(nonce, plaintext, ciphertext, tag);
        return new EncryptedEnvelope(1, Convert.ToBase64String(nonce), Convert.ToBase64String(ciphertext), Convert.ToBase64String(tag), DateTimeOffset.UtcNow);
    }
    private static T Decrypt<T>(EncryptedEnvelope envelope, byte[] key)
    {
        var nonce = Convert.FromBase64String(envelope.Nonce);
        var ciphertext = Convert.FromBase64String(envelope.Ciphertext);
        var tag = Convert.FromBase64String(envelope.Tag);
        var plaintext = new byte[ciphertext.Length];
        using (var aes = new AesGcm(key, 16)) aes.Decrypt(nonce, ciphertext, tag, plaintext);
        return JsonSerializer.Deserialize<T>(plaintext, Json)!;
    }
    private static async Task Ensure(HttpResponseMessage response, CancellationToken ct) { if (!response.IsSuccessStatusCode) throw new InvalidOperationException((await response.Content.ReadAsStringAsync(ct)).Trim()); }

    private static ECDiffieHellman ImportX963(string value)
    {
        var data = Convert.FromBase64String(value); if (data.Length != 65 || data[0] != 4) throw new InvalidOperationException("Invalid iPhone public key");
        var ec = ECDiffieHellman.Create(); ec.ImportParameters(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = data[1..33], Y = data[33..65] } }); return ec;
    }
    private static string ExportX963(ECDiffieHellman key) { var p = key.ExportParameters(false); return Convert.ToBase64String(new byte[] { 4 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray()); }
    private static byte[] HkdfExpand(byte[] prk, int length)
    {
        var output = new byte[length]; var previous = Array.Empty<byte>(); var offset = 0; byte counter = 1;
        while (offset < length) { using var hmac = new HMACSHA256(prk); var block = hmac.ComputeHash(previous.Concat(new byte[] { counter++ }).ToArray()); var take = Math.Min(block.Length, length - offset); Array.Copy(block, 0, output, offset, take); offset += take; previous = block; }
        return output;
    }
    private sealed record CommandBox(string Id, string Kind, DateTimeOffset ExpiresAt, EncryptedEnvelope Envelope);
    private sealed record PushedCommand(string Type, CommandBox Command);
    private sealed record EventPayload(IReadOnlyList<RemoteStreamItem> Items, SessionCapabilities? Capabilities, RemoteApprovalRequest? Approval, string? ResolvedApprovalRequestId, string? ActiveTurnId);
}
