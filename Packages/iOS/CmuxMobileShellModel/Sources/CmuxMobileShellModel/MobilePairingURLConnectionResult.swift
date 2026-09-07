import Foundation

/// The result of attempting to connect from a pairing URL.
public enum MobilePairingURLConnectionResult: Equatable, Sendable {
    /// The pairing URL produced a live connection.
    case connected
    /// DeviceLink enrollment and local persistence succeeded, but the first
    /// ordinary connection did not. The pairing is durable and retryable, so
    /// callers must leave the scanner instead of asking for the same QR again.
    case pairedOffline
    /// The pairing URL failed to connect.
    case failed
    /// The pairing URL is waiting for explicit user approval before dialing.
    case needsUserApproval
    /// A newer connection attempt superseded this one before it completed.
    case superseded

    /// Whether the result represents a successful connection.
    public var didConnect: Bool {
        self == .connected
    }

    /// Whether the URL established durable pairing authority.
    public var didPair: Bool {
        self == .connected || self == .pairedOffline
    }
}
