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
        guard host.contains(":") else { return false }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        if host.hasPrefix("fe80:") { return true }
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
        if host.hasPrefix("::ffff:") {
            let mapped = String(host.dropFirst(7))
            if let ipv4 = ipv4Octets(mapped) { return isPrivateOrLoopbackIPv4(ipv4) }
        }
        return false
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
