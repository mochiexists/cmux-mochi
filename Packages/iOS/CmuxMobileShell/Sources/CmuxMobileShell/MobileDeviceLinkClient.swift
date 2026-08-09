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
    // lint:allow singleton — the transport supplies process-wide synchronous TLS
    // callbacks, so the credential and active-dial state must share one owner.
    public static let shared = MobileDeviceLinkClient()

    private let identityStore: KeychainDeviceIdentityStore
    private let pinStore: KeychainServerPinStore
    // lint:allow lock — protects the small cache/dial-target snapshot used by
    // synchronous Network.framework callbacks that cannot await an actor.
    private let lock = NSLock()
    private var cachedIdentities: [String: SecIdentity] = [:]
    /// macDeviceID -> pairingID, so a dial can find the right key.
    private lazy var pairingIDsByMacDeviceID: [String: String] =
        (UserDefaults.standard.dictionary(forKey: Self.pairingIndexDefaultsKey) as? [String: String]) ?? [:]

    private static var keychainScope: KeychainScope {
        KeychainScope(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.cmux-mochi.ios")
    }

    /// Routes TLS verify-block outcomes into the device log.
    ///
    /// Installed once, at first use of the client. A handshake that fails
    /// inside the verify block is otherwise completely silent on this side.
    private static let installVerificationObserver: Void = {
        DeviceLinkTLS.verificationObserver = { message in
            MobileDeviceLinkDiagnostics.log(message)
        }
    }()

    public init(scope: KeychainScope? = nil) {
        _ = Self.installVerificationObserver
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
    ///
    /// Also drops the Mac -> pairing mapping and any dial target pointing at
    /// this pairing. Leaving either behind lets a later dial resolve a mapping
    /// to an identity that no longer exists, and
    /// ``currentPairingTLSOptions()`` then falls back to *another* Mac's pin —
    /// offering the wrong key, which fails as an unreachable Mac.
    public func forget(pairingID: String) {
        lock.lock()
        cachedIdentities[pairingID] = nil
        let staleTargets = pairingIDsByMacDeviceID
            .filter { $0.value == pairingID }
            .map(\.key)
        for macDeviceID in staleTargets {
            pairingIDsByMacDeviceID[macDeviceID] = nil
            if activeDialTarget == macDeviceID { activeDialTarget = nil }
        }
        let snapshot = pairingIDsByMacDeviceID
        lock.unlock()
        if !staleTargets.isEmpty {
            UserDefaults.standard.set(snapshot, forKey: Self.pairingIndexDefaultsKey)
        }
        if let material = try? identityStore.identity(forPairingID: pairingID) {
            SecIdentityFactory.removeIdentity(for: material)
        }
        try? identityStore.remove(pairingID: pairingID)
        try? pinStore.removePin(forPairingID: pairingID)
    }

    /// Forgets whatever pairing this device holds for one Mac.
    ///
    /// Unpairing is expressed in the UI as "remove this computer", which knows
    /// only a Mac device id. Without this the deletion removed the row and left
    /// the key and pin in the keychain: ``hasAnyPairedDevice()`` stayed true
    /// with nothing listed, and re-scanning that Mac's QR code reused the same
    /// identity, so the Mac reported it as already enrolled. That is not a
    /// delete, and the re-pair it appears to offer never really happens.
    ///
    /// - Returns: the pairing that was forgotten, if this device had one.
    @discardableResult
    public func forgetPairing(macDeviceID: String) -> String? {
        lock.lock()
        let pairingID = pairingIDsByMacDeviceID[macDeviceID]
        lock.unlock()
        guard let pairingID else { return nil }
        forget(pairingID: pairingID)
        return pairingID
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

    /// Which Mac the next dial is for, keyed by its device id.
    ///
    /// The transport asks for TLS options through a closure that knows only
    /// "give me an identity", so the caller that *does* know which Mac it is
    /// dialing records it here first. Without this the client offers whichever
    /// pin sorts first, and with more than one paired Mac that is the wrong key
    /// most of the time — the dial then dies in the TLS handshake, which is
    /// indistinguishable from the Mac being switched off.
    private var activeDialTarget: String?

    /// Remembers which pairing belongs to a Mac, so a later dial can pick its
    /// key. Written at enrollment, where both halves are known.
    ///
    /// Kept next to the pins rather than in the paired-Mac database because the
    /// database has no fingerprint column, and the pin store is already the
    /// authority on which pairings exist.
    public func rememberPairing(macDeviceID: String, pairingID: String) {
        guard !macDeviceID.isEmpty, !pairingID.isEmpty else { return }
        lock.lock()
        pairingIDsByMacDeviceID[macDeviceID] = pairingID
        let snapshot = pairingIDsByMacDeviceID
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: Self.pairingIndexDefaultsKey)
    }

    /// Declares the Mac the next dial targets.
    public func setActiveDialTarget(macDeviceID: String?) {
        lock.lock()
        activeDialTarget = macDeviceID
        lock.unlock()
    }

    private static let pairingIndexDefaultsKey = "devicelink.pairingIDsByMacDeviceID"

    public func currentPairingTLSOptions() -> NWProtocolTLS.Options? {
        // Prefer the pin for the Mac actually being dialed.
        lock.lock()
        let target = activeDialTarget
        let mapped = target.flatMap { pairingIDsByMacDeviceID[$0] }
        lock.unlock()
        if let mapped, let options = tlsOptions(forPairingID: mapped) {
            MobileDeviceLinkDiagnostics.log("tls options: offering \(mapped.prefix(24)) for target \(target?.prefix(12) ?? "?")")
            return options
        }
        if target != nil, mapped == nil {
            MobileDeviceLinkDiagnostics.log(
                "tls options: no pairing recorded for target \(target?.prefix(12) ?? "?") — falling back to first pin"
            )
        }
        return firstAvailableTLSOptions()
    }

    private func firstAvailableTLSOptions() -> NWProtocolTLS.Options? {
        let pins: [String: DeviceFingerprint]
        do {
            pins = try pinStore.pins()
        } catch {
            MobileDeviceLinkDiagnostics.log("tls options: pin store unreadable (\(error))")
            return nil
        }
        // Which pin was offered matters as much as whether one was found: this
        // picks the first, so with more than one paired Mac it can present the
        // wrong key and the dial dies in the TLS handshake — indistinguishable,
        // from the phone, from an unreachable Mac.
        for pairingID in pins.keys.sorted() {
            if let options = tlsOptions(forPairingID: pairingID) {
                MobileDeviceLinkDiagnostics.log(
                    "tls options: offering \(pairingID.prefix(24)) of \(pins.count) pin(s)"
                )
                return options
            }
            MobileDeviceLinkDiagnostics.log("tls options: no identity for \(pairingID.prefix(24))")
        }
        if pins.isEmpty {
            MobileDeviceLinkDiagnostics.log("tls options: no pins stored")
        }
        return nil
    }

    /// Records whether the transport layer got TLS options when it asked.
    ///
    /// A `nil` here means the dial proceeds in plaintext against a TLS-only
    /// host, which fails as a connection timeout rather than an auth error —
    /// the single most misleading failure in this path.
    public static func reportTLSOptionsLookup(succeeded: Bool) {
        MobileDeviceLinkDiagnostics.log("transport asked for TLS options: \(succeeded ? "provided" : "NONE")")
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
