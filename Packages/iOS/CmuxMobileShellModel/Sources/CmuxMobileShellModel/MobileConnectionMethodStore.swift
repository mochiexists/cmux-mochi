public import Foundation
import Observation

/// How the phone should reach a paired Mac.
public enum MobileConnectionMethod: String, CaseIterable, Sendable {
    /// Dial the built-in encrypted peer-to-peer transport (direct paths with
    /// managed relays as fallback). The default; no setup required.
    case automatic
    /// Prefer the user's Tailscale network. Requires entering the Tailscale
    /// pairing code shown on the Mac once, which authorizes that exact peer.
    case tailscale
}

/// Persists the user's connection-method choice.
///
/// The preference only reorders dialing: `tailscale` puts authorized Tailscale
/// routes ahead of the automatic transport instead of the default pin that
/// dials the automatic transport exclusively. It never manufactures Tailscale
/// authorization by itself; a pairing code entry remains the authorization
/// event for each Mac.
///
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard`; the app constructs it at the composition root.
@MainActor
@Observable
public final class MobileConnectionMethodStore {
    /// The defaults key under which the connection method is stored.
    public static let methodKey = "dev.cmux.mobile.connectionMethod.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// The user's current connection-method choice.
    public var method: MobileConnectionMethod {
        didSet {
            guard method != oldValue else { return }
            defaults.set(method.rawValue, forKey: Self.methodKey)
        }
    }

    /// Create a store backed by the given defaults.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        // Fork (cmux Mochi): the automatic transport dials upstream's
        // account-backed managed relays, which this fork does not run — for us
        // it can only search and fail ("Couldn't connect to your Mac yet").
        // Tailscale/QR is this fork's real pairing path, so it is the default,
        // and a stored `automatic` (upstream's default, possibly persisted by
        // an older build) is coerced rather than honored so existing installs
        // stop preferring a dead transport.
        if let rawValue = defaults.string(forKey: Self.methodKey),
           let method = MobileConnectionMethod(rawValue: rawValue),
           method != .automatic {
            self.method = method
        } else {
            self.method = .tailscale
        }
    }
}
