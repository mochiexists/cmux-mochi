import DeviceLinkKit
import Foundation
import Network
import OSLog
import Security

private let deviceLinkLog = Logger(subsystem: "dev.cmux", category: "mobile-devicelink")

/// Records a DeviceLink event to os_log **and** stdout.
///
/// A tagged dev build launched from a shell has its stdout captured, while its
/// `os_log` output has proven unretrievable in practice — every pairing
/// diagnosis so far has been done with the Mac's half invisible, which is why
/// several wrong conclusions survived as long as they did. Cheap insurance.
func logDeviceLinkHost(_ message: String) {
    deviceLinkLog.info("devicelink: \(message, privacy: .public)")
    #if DEBUG
    print("devicelink · \(message)")
    fflush(stdout)
    #endif
}

/// The Mac's DeviceLink state: its own TLS identity, the authorized-devices
/// table, and the coordinator that serializes admission against revocation.
///
/// Fork (cmux Mochi): this replaces the attach-ticket bearer model for device
/// pairing entirely. A phone proves possession of a private key over mutual
/// TLS; the Mac keeps only public fingerprints. See
/// `plans/feat-account-free-reconnect/DESIGN.md`.
///
/// The heavy lifting lives in `DeviceLinkKit` so it can be shared with other
/// apps and so upstream merges see only this thin integration layer.
@MainActor
final class MobileHostDeviceLink {
    static let shared = MobileHostDeviceLink()

    /// Where this app instance's keychain items live. Bundle id plus instance
    /// tag, so Stable/Nightly/tagged-dev builds on one Mac never share a table.
    private static var keychainScope: KeychainScope {
        KeychainScope(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.cmux",
            instanceTag: MobileHostIdentity.instanceTag()
        )
    }

    let coordinator: DeviceLinkCoordinator
    /// Synchronously-readable view of what may be admitted.
    ///
    /// The TLS verify block runs on a Network.framework callback thread and
    /// must answer without awaiting: blocking it on a semaphore while an actor
    /// call completes stalls the handshake until the connect deadline, which
    /// looks exactly like an unreachable Mac. This snapshot is refreshed
    /// whenever the table or the enrollment window changes.
    private let admissionSnapshot = MobileHostDeviceLinkAdmissionSnapshot()
    private let identityStore: KeychainDeviceIdentityStore
    private var cachedIdentity: (material: DeviceIdentityMaterial, secIdentity: SecIdentity)?
    private var didLoad = false

    /// Identity slot for the Mac's own listener certificate. The Mac presents
    /// one identity to every phone (it is the identified party); phones keep a
    /// distinct identity per Mac.
    private static let hostIdentitySlot = "host"

    private init() {
        let scope = Self.keychainScope
        coordinator = DeviceLinkCoordinator(store: KeychainAuthorizedDeviceStore(scope: scope))
        identityStore = KeychainDeviceIdentityStore(scope: scope)
    }

    /// Loads the authorized-devices table.
    ///
    /// Must complete before the listener reports ready, otherwise a phone can
    /// race a cold start and be told its perfectly good key is unknown.
    func prepare() async {
        guard !didLoad else { return }
        do {
            let wasRejected = try await coordinator.load()
            if wasRejected {
                deviceLinkLog.error(
                    "devicelink: stored device table was unreadable; every device must re-pair"
                )
            }
            didLoad = true
            await refreshAdmissionSnapshot()
        } catch {
            deviceLinkLog.error("devicelink: device table load failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// This Mac's SPKI fingerprint, for the pairing QR.
    func hostFingerprint() -> DeviceFingerprint? {
        try? hostIdentity().material.fingerprint
    }

    /// Same as ``hostFingerprint()`` but surfaces why it failed.
    ///
    /// Identity setup touches the keychain, which fails in ways worth naming
    /// (locked, unentitled, corrupt) rather than collapsing to "unavailable".
    func hostFingerprintOrThrow() throws -> DeviceFingerprint {
        try hostIdentity().material.fingerprint
    }

    /// TLS options for the pairing listener.
    ///
    /// The verify block answers "is this key one of ours?" by asking the
    /// coordinator, so table reads are ordered against revocations. An unknown
    /// key is admitted **only** while an enrollment window is open, and even
    /// then the connection is restricted to the enrollment verb.
    func listenerOptions() throws -> NWProtocolTLS.Options {
        let identity = try hostIdentity().secIdentity
        let snapshot = admissionSnapshot
        // Load the table into the snapshot the moment the listener exists.
        // Without this the snapshot starts empty and stays empty until
        // something incidental refreshes it, so a Mac that has just launched
        // rejects every device it is paired with — pairing still works, because
        // minting a code refreshes it, which is exactly why this hid.
        Task { await refreshAdmissionSnapshot() }
        return DeviceLinkTLS.listenerOptions(identity: identity) { fingerprint in
            // Answers from the snapshot, never awaiting. See
            // `admissionSnapshot` for why blocking here is not an option.
            let admitted = snapshot.admits(fingerprint)
            logDeviceLinkHost("verify \(fingerprint.shortForm) -> \(admitted ? "admit" : "REJECT") \(snapshot.describe())")
            return admitted
        }
    }

    /// Refreshes the snapshot the verify block reads.
    private func refreshAdmissionSnapshot() async {
        let authorized = await coordinator.devices().map(\.fingerprint)
        let enrolling = await coordinator.hasOpenEnrollmentWindow()
        admissionSnapshot.update(authorized: Set(authorized), enrollmentWindowOpen: enrolling)
        logDeviceLinkHost("admission snapshot -> \(authorized.count) authorized, enrolling=\(enrolling)")
    }

    /// Classifies a completed handshake into the authorization context the
    /// connection should run under.
    ///
    /// Derived from the TLS peer certificate — never from anything the client
    /// asserts in a request body.
    func authorizationContext(
        forPeer fingerprint: DeviceFingerprint
    ) async -> MobileHostConnectionAuthorizationContext {
        if await coordinator.isAuthorized(fingerprint) {
            let label = await coordinator.devices()
                .first { $0.fingerprint == fingerprint }?
                .label ?? "paired device"
            return .pairedDevice(fingerprint: fingerprint.hex, label: label)
        }
        return .enrollmentCandidate(fingerprint: fingerprint.hex)
    }

    /// Mints an enrollment ticket for a pairing QR.
    /// - Parameter lifetime: How long the code stays scannable. Short by
    ///   default: the window is the whole exposure a photographed QR creates.
    func issueEnrollmentTicket(
        lifetime: TimeInterval = EnrollmentTicket.defaultLifetime
    ) async throws -> EnrollmentTicket {
        await prepare()
        let ticket = try await coordinator.issueEnrollmentTicket(lifetime: lifetime)
        await refreshAdmissionSnapshot()
        return ticket
    }

    /// Enrolls a device that presented a valid ticket over a pinned channel.
    func enroll(
        ticketSecret: String,
        fingerprint: DeviceFingerprint,
        label: String
    ) async throws -> EnrollmentOutcome {
        let outcome = try await coordinator.redeem(
            ticketSecret: ticketSecret,
            fingerprint: fingerprint,
            rawLabel: label
        )
        // The operator sees every enrollment: a covertly-scanned QR should not
        // be a silent event on the machine it targets.
        await refreshAdmissionSnapshot()
        MobileHostDeviceLinkNotifier.postEnrollment(device: outcome.device)
        deviceLinkLog.info(
            "devicelink: enrolled \(outcome.device.displayName, privacy: .public) (existing: \(outcome.wasAlreadyEnrolled, privacy: .public))"
        )
        return outcome
    }

    /// Marks a device as seen, so a reconnect is visible in `device.list`.
    func noteAdmission(_ fingerprint: DeviceFingerprint) async {
        _ = await coordinator.registerAdmission(fingerprint, connectionID: UUID())
    }

    /// Every enrolled device, for `mobile.pairing.device.list`.
    func devices() async -> [AuthorizedDevice] {
        await prepare()
        return await coordinator.devices()
    }

    /// Revokes a device and closes its live connections.
    func revoke(fingerprintHex: String) async throws -> Bool {
        guard let fingerprint = DeviceFingerprint(hex: fingerprintHex) else { return false }
        await prepare()
        let didRevoke = try await coordinator.revoke(fingerprint)
        await refreshAdmissionSnapshot()
        return didRevoke
    }

    /// Fallback identity slot for Macs whose primary slot is poisoned by an
    /// unreachable keychain relic. An earlier build's `kSecAttrAccessible`
    /// write shadow-routed the item into the data-protection keychain, where
    /// this (unentitled) app can neither read, update, nor delete it — yet
    /// `SecItemAdd`'s uniqueness check still collides with it, so the primary
    /// slot wedges with errSecDuplicateItem forever. The relic is dead weight;
    /// the identity simply lives under a different account on such Macs.
    /// Healthy Macs never touch this slot, so their identities (and their
    /// phones' pinned fingerprints) are unaffected.
    private static let hostIdentityFallbackSlot = "host.v2"

    /// Loads or creates this Mac's TLS identity.
    private func hostIdentity() throws -> (material: DeviceIdentityMaterial, secIdentity: SecIdentity) {
        if let cachedIdentity { return cachedIdentity }

        let material: DeviceIdentityMaterial
        if let existing = try identityStore.identity(forPairingID: Self.hostIdentitySlot) {
            material = existing
        } else if let fallback = try identityStore.identity(forPairingID: Self.hostIdentityFallbackSlot) {
            material = fallback
        } else {
            // A locked keychain throws above rather than returning nil, so
            // reaching here means the slots are genuinely empty — never "we
            // could not look", which would orphan every existing pairing.
            material = try DeviceIdentityMaterial.generate(commonName: "cmux-mac")
            do {
                try identityStore.save(material, forPairingID: Self.hostIdentitySlot)
            } catch KeychainStorageError.unexpectedStatus(errSecDuplicateItem) {
                // Primary slot poisoned (see hostIdentityFallbackSlot doc).
                try identityStore.save(material, forPairingID: Self.hostIdentityFallbackSlot)
                deviceLinkLog.warning("devicelink: primary identity slot poisoned by an unreachable keychain relic; using the fallback slot")
            }
            deviceLinkLog.info("devicelink: generated host identity \(material.fingerprint.shortForm, privacy: .public)")
        }

        let secIdentity = try SecIdentityFactory.makeIdentity(from: material)
        let resolved = (material, secIdentity)
        cachedIdentity = resolved
        return resolved
    }
}

/// Posts a user-visible notification when a device enrolls.
enum MobileHostDeviceLinkNotifier {
    static let didEnrollDevice = Notification.Name("dev.cmux.devicelink.didEnrollDevice")

    static func postEnrollment(device: AuthorizedDevice) {
        NotificationCenter.default.post(
            name: didEnrollDevice,
            object: nil,
            userInfo: ["displayName": device.displayName]
        )
    }
}
