public import Foundation
internal import Crypto

/// Errors surfaced while minting or redeeming an enrollment ticket.
public enum EnrollmentError: Error, Equatable {
    /// The platform CSPRNG failed. DeviceLink **fails closed**: it never falls
    /// back to a weaker source for a credential-bearing value.
    case secureRandomnessUnavailable
    /// No such ticket, or it was already consumed, or it expired. Deliberately
    /// one case: a caller probing for ticket existence learns nothing.
    case ticketUnusable
    /// The authorized-devices table is at capacity.
    case deviceQuotaExceeded
    /// Enrollment attempts are arriving faster than the throttle permits.
    case throttled
    /// Persisting the new row failed; the ticket is left **unconsumed** so a
    /// retry can still succeed.
    case persistenceFailed
}

/// A single-use, short-lived capability that authorizes exactly one unknown
/// device to enroll.
///
/// This is the only bearer-shaped value in DeviceLink. It is deliberately
/// weak: ten minutes, one use, and its sole power is to add a public key to
/// the authorized-devices table — an act that is announced to the operator and
/// individually revocable.
public struct EnrollmentTicket: Sendable, Equatable {
    /// Opaque high-entropy value carried in the pairing QR.
    public let secret: String
    /// When the ticket stops being redeemable.
    public let expiresAt: Date

    /// Default lifetime. Long enough to walk to the other machine and scan,
    /// short enough that a photographed code is nearly worthless.
    public static let defaultLifetime: TimeInterval = 10 * 60

    /// Mints a ticket using the platform CSPRNG.
    /// - Parameters:
    ///   - lifetime: How long the ticket remains redeemable.
    ///   - now: Injected clock for tests.
    /// - Returns: A fresh ticket.
    /// - Throws: ``EnrollmentError/secureRandomnessUnavailable`` if the CSPRNG
    ///   fails — never a degraded substitute.
    public static func mint(
        lifetime: TimeInterval = EnrollmentTicket.defaultLifetime,
        now: Date = Date()
    ) throws -> EnrollmentTicket {
        var bytes = [UInt8](repeating: 0, count: 32)
        do {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
            }
        }
        // `SystemRandomNumberGenerator` traps rather than returning weak bytes,
        // so reaching here means the platform CSPRNG succeeded. The all-zero
        // check is a cheap tripwire against a future substitution.
        guard bytes.contains(where: { $0 != 0 }) else {
            throw EnrollmentError.secureRandomnessUnavailable
        }
        let secret = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return EnrollmentTicket(secret: secret, expiresAt: now.addingTimeInterval(lifetime))
    }

    /// Whether the ticket may still be redeemed at the given instant.
    public func isRedeemable(at now: Date = Date()) -> Bool {
        now < expiresAt
    }
}

/// The outcome of a successful enrollment.
public struct EnrollmentOutcome: Sendable, Equatable {
    /// The row now present in the authorized-devices table.
    public let device: AuthorizedDevice
    /// Whether this fingerprint was already enrolled. A repeat enrollment
    /// refreshes the label instead of creating a duplicate — which is what
    /// makes a lost enrollment response harmless.
    public let wasAlreadyEnrolled: Bool
}
