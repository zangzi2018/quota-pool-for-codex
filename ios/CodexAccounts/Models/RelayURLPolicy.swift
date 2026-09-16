import Darwin
import Foundation

enum RelayURLPolicyError: LocalizedError, Equatable {
    case invalid
    case insecure
    case credentialsInURL

    var errorDescription: String? {
        switch self {
        case .invalid: "Invalid relay URL"
        case .insecure: "Public relays must use HTTPS"
        case .credentialsInURL: "Relay URL must not include a username or password"
        }
    }
}

enum RelayURLPolicy {
    struct Result: Equatable {
        let url: URL
        let usesCleartext: Bool
    }

    static func parse(_ string: String) throws -> Result {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw RelayURLPolicyError.invalid
        }
        guard url.user == nil, url.password == nil else { throw RelayURLPolicyError.credentialsInURL }
        if scheme == "https" { return Result(url: url, usesCleartext: false) }
        if scheme == "http", isTrustedCleartextHost(host) { return Result(url: url, usesCleartext: true) }
        if scheme == "http" { throw RelayURLPolicyError.insecure }
        throw RelayURLPolicyError.invalid
    }

    static func isTrustedCleartextHost(_ host: String) -> Bool {
        let hostname = host.lowercased()
        if hostname == "localhost" || hostname == "localhost.localdomain" { return true }
        if hostname.hasSuffix(".localhost") || hostname.hasSuffix(".local") { return true }
        if let ipv4 = ipv4Octets(hostname) { return isPrivateOrLoopbackIPv4(ipv4) }
        return isPrivateOrLoopbackIPv6(hostname)
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivateOrLoopbackIPv4(_ octets: [Int]) -> Bool {
        if octets[0] == 127 { return true }
        if octets[0] == 10 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 169 && octets[1] == 254 { return true }
        return false
    }

    private static func isPrivateOrLoopbackIPv6(_ host: String) -> Bool {
        guard host.contains(":"), let bytes = ipv6Bytes(host), bytes.count == 16 else { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        if (bytes[0] & 0xfe) == 0xfc { return true }
        if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isPrivateOrLoopbackIPv4([Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15])])
        }
        return false
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        let ok = host.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
        guard ok else { return nil }
        return withUnsafeBytes(of: addr) { Array($0.prefix(16)) }
    }
}

enum RelayTransport {
    private static let redirectGuard = RelayRedirectGuard()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }
}

private final class RelayRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
