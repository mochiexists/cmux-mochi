public import DeviceLinkKit
public import Foundation
public import Network
internal import Security

protocol MobileDeviceIdentityStoring: Sendable {
    func identity(forPairingID pairingID: String) throws -> DeviceIdentityMaterial?
    func save(_ material: DeviceIdentityMaterial, forPairingID pairingID: String) throws
    func remove(pairingID: String) throws
}

protocol MobileServerPinStoring: Sendable {
    func pins() throws -> [String: DeviceFingerprint]
    func setPin(_ fingerprint: DeviceFingerprint, forPairingID pairingID: String) throws
    func removePin(forPairingID pairingID: String) throws
}

private struct MobileKeychainIdentityStore: MobileDeviceIdentityStoring {
    private let store: DeviceLinkKit.KeychainDeviceIdentityStore

    init(scope: KeychainScope) {
        store = DeviceLinkKit.KeychainDeviceIdentityStore(scope: scope)
    }

    func identity(forPairingID pairingID: String) throws -> DeviceIdentityMaterial? {
        try store.identity(forPairingID: pairingID)
    }

    func save(_ material: DeviceIdentityMaterial, forPairingID pairingID: String) throws {
        try store.save(material, forPairingID: pairingID)
    }

    func remove(pairingID: String) throws {
        try store.remove(pairingID: pairingID)
    }
}

private struct MobileKeychainPinStore: MobileServerPinStoring {
    private let store: KeychainServerPinStore

    init(scope: KeychainScope) {
        store = KeychainServerPinStore(scope: scope)
    }

    func pins() throws -> [String: DeviceFingerprint] {
        try store.pins()
    }

    func setPin(_ fingerprint: DeviceFingerprint, forPairingID pairingID: String) throws {
        try store.setPin(fingerprint, forPairingID: pairingID)
    }

    func removePin(forPairingID pairingID: String) throws {
        try store.removePin(forPairingID: pairingID)
    }
}

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

    private let identityStore: any MobileDeviceIdentityStoring
    private let pinStore: any MobileServerPinStoring
    private let pairingIndexDefaults: UserDefaults
    // lint:allow lock — protects the small cache/dial-target snapshot used by
    // synchronous Network.framework callbacks that cannot await an actor.
    private let lock = NSLock()
    private var cachedIdentities: [String: SecIdentity] = [:]
    /// build-scoped Mac key -> pairingID, so Stable/Nightly/tagged siblings
    /// sharing one physical `macDeviceID` still offer distinct credentials.
    /// Legacy installs used the raw Mac id as the key; tagged lookups retain a
    /// read fallback until one authenticated connection promotes the concrete
    /// app instance.
    private lazy var pairingIDsByMacDeviceID: [String: String] =
        (pairingIndexDefaults.dictionary(forKey: Self.pairingIndexDefaultsKey) as? [String: String]) ?? [:]

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

    public convenience init(scope: KeychainScope? = nil) {
        let resolved = scope ?? Self.keychainScope
        self.init(
            identityStore: MobileKeychainIdentityStore(scope: resolved),
            pinStore: MobileKeychainPinStore(scope: resolved),
            pairingIndexDefaults: .standard
        )
    }

    init(
        identityStore: any MobileDeviceIdentityStoring,
        pinStore: any MobileServerPinStoring,
        pairingIndexDefaults: UserDefaults
    ) {
        _ = Self.installVerificationObserver
        self.identityStore = identityStore
        self.pinStore = pinStore
        self.pairingIndexDefaults = pairingIndexDefaults
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
    /// Also drops every Mac -> pairing mapping for this identity. Retaining a
    /// stale mapping would make that Mac look paired and permanently undialable.
    public func forget(pairingID: String) {
        lock.lock()
        cachedIdentities[pairingID] = nil
        let staleTargets = pairingIDsByMacDeviceID
            .filter { $0.value == pairingID }
            .map(\.key)
        for indexKey in staleTargets {
            pairingIDsByMacDeviceID[indexKey] = nil
        }
        let snapshot = pairingIDsByMacDeviceID
        lock.unlock()
        if !staleTargets.isEmpty {
            pairingIndexDefaults.set(snapshot, forKey: Self.pairingIndexDefaultsKey)
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
    public func forgetPairing(
        macDeviceID: String,
        instanceTag: String? = nil
    ) -> String? {
        lock.lock()
        let pairingID = pairingIDLocked(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        lock.unlock()
        guard let pairingID else { return nil }
        forget(pairingID: pairingID)
        return pairingID
    }

    /// Whether this device holds a usable key and pin for one specific Mac.
    ///
    /// The reconnect path asks this to decide whether it may dial that Mac
    /// directly with its own identity, rather than going through the
    /// bearer-oriented ticket exchange (which has no answer for a pairing whose
    /// credential *is* the device key). `forgetPairing` is the only other way
    /// to resolve a Mac to its pairing, and that one destroys it.
    public func hasUsableCredential(
        forMacDeviceID macDeviceID: String,
        instanceTag: String? = nil
    ) -> Bool {
        lock.lock()
        let pairingID = pairingIDLocked(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        lock.unlock()
        guard let pairingID else { return false }
        return hasUsableCredential(forPairingID: pairingID)
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

    /// Remembers which pairing belongs to a Mac, so a later dial can pick its
    /// key. Written at enrollment, where both halves are known.
    ///
    /// Kept next to the pins rather than in the paired-Mac database because the
    /// database has no fingerprint column, and the pin store is already the
    /// authority on which pairings exist.
    public func rememberPairing(
        macDeviceID: String,
        instanceTag: String? = nil,
        pairingID: String
    ) {
        guard !macDeviceID.isEmpty, !pairingID.isEmpty else { return }
        let indexKey = Self.pairingIndexKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        lock.lock()
        pairingIDsByMacDeviceID[indexKey] = pairingID
        let snapshot = pairingIDsByMacDeviceID
        lock.unlock()
        pairingIndexDefaults.set(snapshot, forKey: Self.pairingIndexDefaultsKey)
    }

    /// Moves an installed mac-only mapping to the concrete app instance after
    /// a successful authenticated connection proves which row owns it.
    ///
    /// Legacy installs could record only the physical Mac id. Keeping that
    /// fallback after a tagged connection would let Stable and Nightly both
    /// claim the same private key. Promotion makes the proven tag exact and
    /// makes every sibling fail closed until it is paired independently.
    public func promoteLegacyPairing(
        macDeviceID: String,
        instanceTag: String?
    ) {
        guard let instanceTag = Self.normalizedInstanceTag(instanceTag) else { return }
        let exactKey = Self.pairingIndexKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        lock.lock()
        guard let legacyPairingID = pairingIDsByMacDeviceID[macDeviceID] else {
            lock.unlock()
            return
        }
        if pairingIDsByMacDeviceID[exactKey] == nil {
            pairingIDsByMacDeviceID[exactKey] = legacyPairingID
        }
        pairingIDsByMacDeviceID[macDeviceID] = nil
        let snapshot = pairingIDsByMacDeviceID
        lock.unlock()
        pairingIndexDefaults.set(snapshot, forKey: Self.pairingIndexDefaultsKey)
    }

    private static let pairingIndexDefaultsKey = "devicelink.pairingIDsByMacDeviceID"

    private static func pairingIndexKey(
        macDeviceID: String,
        instanceTag: String?
    ) -> String {
        guard let instanceTag = normalizedInstanceTag(instanceTag) else {
            return macDeviceID
        }
        return "v2|\(macDeviceID.utf8.count)|\(macDeviceID)|\(instanceTag)"
    }

    private static func normalizedInstanceTag(_ instanceTag: String?) -> String? {
        guard let normalized = instanceTag?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !normalized.isEmpty else { return nil }
        return normalized
    }

    /// Exact tagged mapping first, then the legacy physical-Mac key. The
    /// fallback keeps existing installs reconnectable; new pairings always
    /// write the tagged key and no longer displace sibling builds.
    private func pairingIDLocked(
        macDeviceID: String,
        instanceTag: String?
    ) -> String? {
        let exactKey = Self.pairingIndexKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        if let exact = pairingIDsByMacDeviceID[exactKey] {
            return exact
        }
        guard Self.normalizedInstanceTag(instanceTag) != nil else { return nil }
        return pairingIDsByMacDeviceID[macDeviceID]
    }

    /// Resolves TLS options for one immutable transport request target.
    ///
    /// Both the physical Mac id and build-scoped instance tag travel with the
    /// request, so simultaneous Stable, Nightly, foreground, and background
    /// dials cannot overwrite each other's credential selection.
    public func pairingTLSOptions(
        forMacDeviceID macDeviceID: String?,
        instanceTag: String?
    ) -> NWProtocolTLS.Options? {
        guard let macDeviceID else {
            MobileDeviceLinkDiagnostics.log(
                "tls options: request has no peer device id — failing closed"
            )
            return nil
        }
        lock.lock()
        let mapped = pairingIDLocked(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        lock.unlock()
        if let mapped, let options = tlsOptions(forPairingID: mapped) {
            MobileDeviceLinkDiagnostics.log(
                "tls options: offering \(mapped.prefix(24)) for target "
                    + "\(macDeviceID.prefix(12)) "
                    + "tag=\(instanceTag ?? "nil")"
            )
            return options
        }
        MobileDeviceLinkDiagnostics.log(
            "tls options: no usable pairing recorded for target "
                + "\(macDeviceID.prefix(12)) "
                + "tag=\(instanceTag ?? "nil") — failing closed"
        )
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
