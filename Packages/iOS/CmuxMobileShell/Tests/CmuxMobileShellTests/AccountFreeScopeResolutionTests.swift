import Foundation
import Testing
@testable import CmuxMobileShell

/// Fork (cmux Mochi): account-free multi-Mac regression.
///
/// The scope contract in `MobileShellComposite+Scope.swift` promises that an
/// account-free session falls back to the install's own local scope
/// (`MobileLocalPairingScope`) so paired Macs stay addressable. But the shell
/// store's `isSignedIn` only ever becomes true through the Stack auth bridge —
/// an account-free (skipped sign-in / QR-paired) session never sets it — so
/// `currentScopeSnapshot()` must not gate the local-scope fallback on it.
/// When it does, `refreshSecondaryMacWorkspaces` bails on its scope guard and
/// every non-foreground Mac sits "Not connected · Presence: unknown" forever:
/// the multi-Mac list renders, but only the single active Mac ever connects.
@Suite struct AccountFreeScopeResolutionTests {
    private func makePairingHintDefaults(hasKnownPairedMac: Bool) -> UserDefaults {
        let suiteName = "accountfree-scope-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if hasKnownPairedMac {
            defaults.set(true, forKey: "cmux.mobile.hasKnownPairedMac")
        }
        return defaults
    }

    /// An account-free session (never signed in, no identity provider) that
    /// holds a pairing must still resolve a scope — the install's local pairing
    /// scope — or the multi-Mac aggregation can never run for QR-paired setups.
    @Test @MainActor func accountFreePairedSessionResolvesLocalScope() async {
        let store = MobileShellComposite(
            isSignedIn: false,
            identityProvider: nil,
            pairingHintDefaults: makePairingHintDefaults(hasKnownPairedMac: true)
        )
        let scope = await store.currentScopeSnapshot()
        #expect(scope != nil)
        #expect(MobileLocalPairingScope.isLocal(scope?.userID))
    }

    /// A local scope captured by an account-free session must stay valid across
    /// the aggregation's awaits, or the pass bails mid-flight after resolving.
    @Test @MainActor func accountFreeLocalScopeStaysCurrent() async {
        let store = MobileShellComposite(
            isSignedIn: false,
            identityProvider: nil,
            pairingHintDefaults: makePairingHintDefaults(hasKnownPairedMac: true)
        )
        guard let scope = await store.currentScopeSnapshot() else {
            Issue.record("account-free paired session resolved no scope")
            return
        }
        #expect(await store.isScopeCurrent(scope))
    }

    /// Before any pairing exists there is nothing to load, and a signed-out
    /// account session must not silently continue under a fresh local scope —
    /// no pairing evidence, no scope.
    @Test @MainActor func unpairedSignedOutSessionResolvesNoScope() async {
        let store = MobileShellComposite(
            isSignedIn: false,
            identityProvider: nil,
            pairingHintDefaults: makePairingHintDefaults(hasKnownPairedMac: false)
        )
        let scope = await store.currentScopeSnapshot()
        #expect(scope == nil)
    }
}
