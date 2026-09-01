using System.Net;
using System.Net.Sockets;

namespace CodexAccounts.Companion;

public static class RelayUrlPolicy
{
    public readonly record struct Result(Uri Url, bool UsesCleartext);

    public static Result Parse(string value)
    {
        var trimmed = value.Trim();
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var url) || string.IsNullOrEmpty(url.Host))
            throw new InvalidOperationException("Invalid relay URL");
        if (!string.IsNullOrEmpty(url.UserInfo))
            throw new InvalidOperationException("Relay URL must not include a username or password");
        var scheme = url.Scheme.ToLowerInvariant();
        if (scheme == Uri.UriSchemeHttps) return new Result(url, false);
        if (scheme == Uri.UriSchemeHttp && IsTrustedCleartextHost(url.Host)) return new Result(url, true);
        if (scheme == Uri.UriSchemeHttp) throw new InvalidOperationException("Public relays must use HTTPS");
        throw new InvalidOperationException("Invalid relay URL");
    }

    public static bool IsTrustedCleartextHost(string host)
    {
        var hostname = host.Trim().TrimStart('[').TrimEnd(']').ToLowerInvariant();
        if (hostname is "localhost" or "localhost.localdomain") return true;
        if (hostname.EndsWith(".localhost", StringComparison.Ordinal) || hostname.EndsWith(".local", StringComparison.Ordinal)) return true;
        if (!IPAddress.TryParse(hostname, out var address)) return false;
        if (IPAddress.IsLoopback(address)) return true;
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var bytes = address.GetAddressBytes();
            if (bytes[0] == 10) return true;
            if (bytes[0] == 192 && bytes[1] == 168) return true;
            if (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) return true;
            if (bytes[0] == 169 && bytes[1] == 254) return true;
            return false;
        }
        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (address.IsIPv6LinkLocal) return true;
            var bytes = address.GetAddressBytes();
            return (bytes[0] & 0xfe) == 0xfc;
        }
        return false;
    }
}
