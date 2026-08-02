public import Foundation

/// One device's currently-reachable endpoints, as published to a directory.
public struct DeviceEndpointAdvertisement: Sendable, Equatable, Codable {
    /// Publisher's public-key identity.
    public let fingerprint: DeviceFingerprint
    /// Endpoints in priority order, formatted `host:port`.
    public var routes: [String]
    /// Display name for pairing UI.
    public var label: String
    /// When this advertisement was written.
    public var updatedAt: Date

    public init(fingerprint: DeviceFingerprint, routes: [String], label: String, updatedAt: Date) {
        self.fingerprint = fingerprint
        self.routes = routes
        self.label = label
        self.updatedAt = updatedAt
    }
}

/// An optional side channel for discovering where a paired device currently
/// lives — and, where the channel is trustworthy, for enrolling without a QR.
///
/// DeviceLink never depends on this. Pairing and reconnection work with nothing
/// but the QR and a stored pin, because external distribution cannot assume a
/// shared account, an iCloud container, or any directory at all. A directory is
/// an accelerator: it removes the "the Mac moved to a new port" re-scan and, if
/// the channel authenticates its writers (a shared iCloud account, say), it can
/// carry public keys so same-account devices pair with no ceremony.
///
/// Implementations must publish **only non-secret material** — fingerprints are
/// public keys, routes are addresses. Nothing here is a credential, so a
/// directory compromise costs discovery convenience, not access.
public protocol DeviceLinkDirectory: Sendable {
    /// Publishes this device's endpoints.
    func publish(_ advertisement: DeviceEndpointAdvertisement) async throws
    /// Reads currently-known advertisements from peers.
    func peers() async throws -> [DeviceEndpointAdvertisement]
    /// Removes this device's advertisement.
    func withdraw(fingerprint: DeviceFingerprint) async throws
}

/// Chooses which endpoints to dial, and in what order.
public enum EndpointResolution {
    /// Merges a stored route list with directory advertisements.
    ///
    /// Stored routes come first: they are what worked last time, and a
    /// directory is eventually consistent — a phone that trusts a stale
    /// advertisement over a working stored route reconnects slower, not faster.
    /// - Parameters:
    ///   - stored: Routes remembered from the last successful session.
    ///   - advertised: Routes from a directory, if one is configured.
    /// - Returns: Deduplicated routes in dial order.
    public static func dialOrder(stored: [String], advertised: [String]) -> [String] {
        var seen = Set<String>()
        return (stored + advertised).filter { route in
            guard !route.isEmpty else { return false }
            return seen.insert(route).inserted
        }
    }
}
