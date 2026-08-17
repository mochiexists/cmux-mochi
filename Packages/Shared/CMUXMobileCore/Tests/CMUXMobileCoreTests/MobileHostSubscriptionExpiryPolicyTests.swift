import Foundation
import Testing
@testable import CMUXMobileCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// A subscription must not outlive the ticket that authorized it.
///
/// Delivery never makes a request, so per-request validation cannot see a
/// subscription lapse: without this rule a ten-minute attach ticket keeps
/// streaming render grids for as long as the connection lives.
@Test func dropsSubscriptionsWhoseTicketHasLapsed() {
    let expired = MobileHostSubscriptionExpiryPolicy.expiredStreamIDs(
        expiries: [
            "lapsed": t0.addingTimeInterval(-1),
            "at-the-instant": t0,
            "still-valid": t0.addingTimeInterval(60),
        ],
        now: t0
    )
    #expect(expired == ["lapsed", "at-the-instant"])
}

/// A credential with no expiry is never dropped.
///
/// This is what keeps the rule from revoking a pairing: a paired device, an
/// iroh peer, and an account session all report `nil`, so binding an expiry
/// can only ever affect a subscription that named a finite lifetime.
@Test func keepsSubscriptionsWithNonExpiringCredentials() {
    let expiries: [String: Date?] = [
        "paired-device": nil,
        "iroh-peer": nil,
        "ticket": t0.addingTimeInterval(-1),
    ]
    #expect(
        MobileHostSubscriptionExpiryPolicy.expiredStreamIDs(expiries: expiries, now: t0)
            == ["ticket"]
    )
    // Even far in the future, a non-expiring credential stays.
    #expect(
        MobileHostSubscriptionExpiryPolicy.expiredStreamIDs(
            expiries: ["paired-device": nil],
            now: t0.addingTimeInterval(86_400 * 365)
        ).isEmpty
    )
}

/// Nothing to drop is the common case and must stay empty.
@Test func reportsNothingWhenEverySubscriptionIsCurrent() {
    #expect(
        MobileHostSubscriptionExpiryPolicy.expiredStreamIDs(expiries: [:], now: t0).isEmpty
    )
    #expect(
        MobileHostSubscriptionExpiryPolicy.expiredStreamIDs(
            expiries: ["a": t0.addingTimeInterval(1), "b": nil],
            now: t0
        ).isEmpty
    )
}
