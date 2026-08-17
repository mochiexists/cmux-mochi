public import Foundation

/// Decides which event subscriptions have outlived the credential that
/// authorized them.
///
/// A subscription is created by an authorized request and then delivers events
/// forever without making another one, so per-request validation can never see
/// it lapse. Binding the credential's lifetime to the subscription is what stops
/// a ten-minute attach ticket from streaming for the life of the connection.
///
/// Pure so the rule is testable without a live connection: the host holds the
/// subscriptions, this decides which of them are past their credential.
public enum MobileHostSubscriptionExpiryPolicy {
    /// Subscriptions whose credential has lapsed at `now`.
    ///
    /// - Parameter expiries: Each subscription's stream id and the moment its
    ///   authorizing credential lapses. `nil` means the credential does not
    ///   expire — a paired device, an iroh peer, or an account session — and is
    ///   never reported, which is what keeps this from revoking a pairing.
    public static func expiredStreamIDs(
        expiries: [String: Date?],
        now: Date
    ) -> Set<String> {
        var expired = Set<String>()
        for (streamID, expiresAt) in expiries {
            guard let expiresAt else { continue }
            // Inclusive: a credential is spent at its expiry instant, not after
            // it. The mint side already applies any grace it wants to the value.
            if expiresAt <= now { expired.insert(streamID) }
        }
        return expired
    }
}
