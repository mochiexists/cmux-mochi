import Darwin
import Foundation

/// Shared classifier for direct private-LAN IPv4 routes.
///
/// Host advertisement and iOS persistence must agree on this boundary. A
/// route advertised as local-network must not be reconstructed as Tailscale
/// after pairing, because that changes both ordering and diagnostics.
public struct CmxPrivateLANHost: Sendable {
    public init() {}

    /// Whether `host` is a canonical IPv4 literal in an RFC 1918 range.
    public func matches(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        guard inet_pton(AF_INET, normalized, &address) == 1 else {
            return false
        }
        let octets = withUnsafeBytes(of: address) { Array($0) }
        guard octets.count == 4 else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }
}
