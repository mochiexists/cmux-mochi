public import DeviceLinkKit
public import Foundation
public import Network
internal import Security

/// The phone's half of DeviceLink: one key pair per paired Mac, the pin for
/// each Mac, and the TLS options that bind them together.
///
/// Fork (cmux Mochi): this replaces the attach-ticket bearer the phone used to
/// keep in memory. The private key never leaves the device and is never sent;
/// the Mac only ever learns the fingerprint. A per-Mac key means theft of one
/// key exposes one pairing, and the same fingerprint never appears to two Macs,
/// so pairings cannot be correlated by an observer who sees both.
public final class MobileDeviceLinkClient: @unchecked Sendable {
    public static let shared = MobileDeviceLinkClient()

    private let identityStore: KeychainDeviceIdentityStore
    private let pinStore: KeychainServerPinStore
    private let lock = NSLock()
    private var cachedIdentities: [String: SecIdentity] = [:]

    private static var keychainScope: KeychainScope {
        KeychainScope(bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.cmux.ios")
    }

    public init(scope: KeychainScope? = nil) {
        let resolved = scope ?? Self.keychainScope
        identityStore = KeychainDeviceIdentityStore(scope: resolved)
        pinStore = KeychainServerPinStore(scope: resolved)
    }

    // MARK: - pairing state

    /// Whether this device holds a usable identity **and** pin for a Mac.
    ///
    /// "Usable" excludes a locked keychain: that is "ask again later", not
    /// "never paired", and answering `true` there would send the user to a
    /// pairing sheet they do not need.
    public func hasUsableCredential(forPairingID pairingID: String) -> Bool {
        do {
            guard try identityStore.identity(forPairingID: pairingID) != nil,
                  try pinStore.pins()[pairingID] != nil
            else { return false }
            return true
        } catch {
            return false
        }
    }

    /// The stored pin for a Mac, if this device has paired with it.
    public func pin(forPairingID pairingID: String) -> DeviceFingerprint? {
        (try? pinStore.pins())?[pairingID]
    }

    /// Creates (or reuses) this device's identity for one Mac and records that
    /// Mac's pin.
    ///
    /// Called **before** the enrollment request is sent, so a response lost in
    /// flight costs nothing: the phone redials with the same identity, and a
    /// Mac that already committed the fingerprint simply admits it.
    @discardableResult
    public func prepareIdentity(
        forPairingID pairingID: String,
        macFingerprint: DeviceFingerprint
    ) throws -> DeviceIdentityMaterial {
        if let existing = try identityStore.identity(forPairingID: pairingID) {
            try pinStore.setPin(macFingerprint, forPairingID: pairingID)
            return existing
        }
        let material = try DeviceIdentityMaterial.generate(commonName: "cmux-iphone")
        try identityStore.save(material, forPairingID: pairingID)
        try pinStore.setPin(macFingerprint, forPairingID: pairingID)
        return material
    }

    /// Forgets a Mac: its pin, this device's key for it, and the keychain items
    /// backing that key. A forgotten pairing leaves nothing behind to reuse.
    public func forget(pairingID: String) {
        lock.lock()
        cachedIdentities[pairingID] = nil
        lock.unlock()
        if let material = try? identityStore.identity(forPairingID: pairingID) {
            SecIdentityFactory.removeIdentity(for: material)
        }
        try? identityStore.remove(pairingID: pairingID)
        try? pinStore.removePin(forPairingID: pairingID)
    }

    /// Whether this device has paired with any Mac.
    ///
    /// The reconnect gate asks this: holding a key and a pin is exactly as good
    /// a reason to dial on launch as an account session, and requiring the
    /// account is what made account-free pairings unable to survive a cold
    /// launch.
    public func hasAnyPairedDevice() -> Bool {
        !((try? pinStore.pins()) ?? [:]).isEmpty
    }

    /// TLS options for whichever Mac this device is paired with.
    ///
    /// The transport layer knows a route, not a pairing, so it asks for the
    /// current one. With a single paired Mac — the common case — this is
    /// unambiguous; with several, the first usable identity is offered and the
    /// Mac's own pin check rejects a mismatch, which is the safe failure.
    public func currentPairingTLSOptions() -> NWProtocolTLS.Options? {
        let pins: [String: DeviceFingerprint]
        do {
            pins = try pinStore.pins()
        } catch {
            MobileDeviceLinkDiagnostics.log("tls options: pin store unreadable (\(error))")
            return nil
        }
        for pairingID in pins.keys.sorted() {
            if let options = tlsOptions(forPairingID: pairingID) {
                return options
            }
            MobileDeviceLinkDiagnostics.log("tls options: no identity for \(pairingID.prefix(24))")
        }
        if pins.isEmpty {
            MobileDeviceLinkDiagnostics.log("tls options: no pins stored")
        }
        return nil
    }

    // MARK: - TLS

    /// Mutual-TLS options for dialing one paired Mac.
    ///
    /// Returns `nil` when this device has no identity or no pin for that Mac,
    /// which the transport treats as "cannot dial" rather than falling back to
    /// plaintext — there is no plaintext pairing host to fall back to.
    public func tlsOptions(forPairingID pairingID: String) -> NWProtocolTLS.Options? {
        guard let expected = pin(forPairingID: pairingID),
              let identity = secIdentity(forPairingID: pairingID)
        else { return nil }
        return DeviceLinkTLS.connectionOptions(
            identity: identity,
            expectedServerFingerprint: expected
        )
    }

    private func secIdentity(forPairingID pairingID: String) -> SecIdentity? {
        // Reported because a missing identity here disables every dial while
        // looking like a network failure.
        lock.lock()
        if let cached = cachedIdentities[pairingID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let material: DeviceIdentityMaterial?
        do {
            material = try identityStore.identity(forPairingID: pairingID)
        } catch {
            MobileDeviceLinkDiagnostics.log("identity read failed: \(error)")
            return nil
        }
        guard let material else {
            MobileDeviceLinkDiagnostics.log("identity missing for \(pairingID.prefix(24))")
            return nil
        }
        let identity: SecIdentity
        do {
            identity = try SecIdentityFactory.makeIdentity(
                from: material,
                label: "cmux-devicelink-\(pairingID)"
            )
        } catch {
            MobileDeviceLinkDiagnostics.log("identity build failed: \(error)")
            return nil
        }

        lock.lock()
        cachedIdentities[pairingID] = identity
        lock.unlock()
        return identity
    }
}
