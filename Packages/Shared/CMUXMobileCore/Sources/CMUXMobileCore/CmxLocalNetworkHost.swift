import Foundation

/// Classifies host names that are safe to treat as direct local-network routes.
///
/// A local route may be either an RFC 1918 IPv4 literal or an mDNS `.local`
/// hostname. The hostname is only a locator: callers must still authenticate
/// the peer (DeviceLink uses mutual TLS and a pinned server certificate).
public struct CmxLocalNetworkHost: Sendable {
    public init() {}

    public func matches(_ host: String) -> Bool {
        if CmxPrivateLANHost().matches(host) {
            return true
        }
        return Self.isMDNSHostname(host)
    }

    private static func isMDNSHostname(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.hasSuffix(".local"), normalized.count > ".local".count else {
            return false
        }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.last == "local", labels.count >= 2 else { return false }
        return labels.dropLast().allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return label.allSatisfy { character in
                character.isASCII
                    && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }
}
