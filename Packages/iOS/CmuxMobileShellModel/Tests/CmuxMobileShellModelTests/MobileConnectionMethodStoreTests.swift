import Foundation
import Testing
@testable import CmuxMobileShellModel

@MainActor
@Suite struct MobileConnectionMethodStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "connection-method-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Fork (cmux Mochi): Tailscale/QR is the fork's pairing path; the automatic
    /// transport dials upstream relays this fork does not run.
    @Test func defaultsToTailscale() {
        let store = MobileConnectionMethodStore(defaults: makeDefaults())
        #expect(store.method == .tailscale)
    }

    @Test func persistsSelectionAcrossInstances() {
        let defaults = makeDefaults()
        let store = MobileConnectionMethodStore(defaults: defaults)
        store.method = .tailscale

        let reloaded = MobileConnectionMethodStore(defaults: defaults)
        #expect(reloaded.method == .tailscale)
    }

    @Test func ignoresUnknownPersistedValue() {
        let defaults = makeDefaults()
        defaults.set("carrier-pigeon", forKey: MobileConnectionMethodStore.methodKey)

        let store = MobileConnectionMethodStore(defaults: defaults)
        #expect(store.method == .tailscale)
    }

    /// Fork (cmux Mochi): an install that persisted `automatic` (upstream's
    /// default, or an older build of this fork) must be coerced to the pairing
    /// path that actually works here — not left preferring a dead transport.
    @Test func coercesPersistedAutomaticToTailscale() {
        let defaults = makeDefaults()
        defaults.set(MobileConnectionMethod.automatic.rawValue, forKey: MobileConnectionMethodStore.methodKey)

        let store = MobileConnectionMethodStore(defaults: defaults)
        #expect(store.method == .tailscale)
    }
}
