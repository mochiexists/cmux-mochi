import Foundation
import Testing
@testable import CmuxMobileShell

/// Fork (cmux Mochi): the account-free scope must behave like a real scope —
/// stable, isolated from accounts, and impossible to confuse with one.
@Suite struct MobileLocalPairingScopeTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "mochi.localScope.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func identifierIsStableAcrossCalls() {
        let defaults = makeDefaults()
        let first = MobileLocalPairingScope.identifier(defaults: defaults)
        let second = MobileLocalPairingScope.identifier(defaults: defaults)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    /// Two installs must not share a scope, or one device's Macs could be read
    /// under another's.
    @Test func separateInstallsGetSeparateScopes() {
        #expect(
            MobileLocalPairingScope.identifier(defaults: makeDefaults())
                != MobileLocalPairingScope.identifier(defaults: makeDefaults())
        )
    }

    /// The namespace is the whole safety property: an account id can never be
    /// mistaken for a local scope, so the two spaces cannot read each other.
    @Test func localScopeIsDistinguishableFromAnAccount() {
        let local = MobileLocalPairingScope.identifier(defaults: makeDefaults())
        #expect(MobileLocalPairingScope.isLocal(local))
        #expect(local.hasPrefix(MobileLocalPairingScope.prefix))

        for accountLike in ["user_mac_123", "", "local", "mochi-local", "stack|abc"] {
            #expect(!MobileLocalPairingScope.isLocal(accountLike))
        }
        #expect(!MobileLocalPairingScope.isLocal(nil))
    }

    /// A corrupt or foreign stored value must be replaced rather than trusted —
    /// otherwise a bad write could alias the scope onto something else.
    @Test func rejectsStoredValueOutsideTheNamespace() {
        let defaults = makeDefaults()
        defaults.set("user_mac_123", forKey: "mochi.pairing.localScopeID")
        let minted = MobileLocalPairingScope.identifier(defaults: defaults)
        #expect(MobileLocalPairingScope.isLocal(minted))
        #expect(minted != "user_mac_123")
    }

    /// A bare prefix with no UUID is not a usable identity.
    @Test func rejectsPrefixOnlyStoredValue() {
        let defaults = makeDefaults()
        defaults.set(MobileLocalPairingScope.prefix, forKey: "mochi.pairing.localScopeID")
        let minted = MobileLocalPairingScope.identifier(defaults: defaults)
        #expect(minted.count > MobileLocalPairingScope.prefix.count)
    }
}
