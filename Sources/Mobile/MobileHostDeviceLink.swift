import DeviceLinkKit
import Foundation
import Network
import OSLog
import Security

private let deviceLinkLog = Logger(subsystem: "dev.cmux", category: "mobile-devicelink")

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
        } catch {
            deviceLinkLog.error("devicelink: device table load failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// This Mac's SPKI fingerprint, for the pairing QR.
    func hostFingerprint() -> DeviceFingerprint? {
        try? hostIdentity().material.fingerprint
    }

    /// TLS options for the pairing listener.
    ///
    /// The verify block answers "is this key one of ours?" by asking the
    /// coordinator, so table reads are ordered against revocations. An unknown
    /// key is admitted **only** while an enrollment window is open, and even
    /// then the connection is restricted to the enrollment verb.
    func listenerOptions() throws -> NWProtocolTLS.Options {
        let identity = try hostIdentity().secIdentity
        let coordinator = coordinator
        return DeviceLinkTLS.listenerOptions(identity: identity) { fingerprint in
            // The verify block is synchronous; bridge to the actor and wait.
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var allowed = false
            Task {
                if await coordinator.isAuthorized(fingerprint) {
                    allowed = true
                } else {
                    allowed = await coordinator.hasOpenEnrollmentWindow()
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
            return allowed
        }
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
    func issueEnrollmentTicket() async throws -> EnrollmentTicket {
        await prepare()
        return try await coordinator.issueEnrollmentTicket()
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
        MobileHostDeviceLinkNotifier.postEnrollment(device: outcome.device)
        deviceLinkLog.info(
            "devicelink: enrolled \(outcome.device.displayName, privacy: .public) (existing: \(outcome.wasAlreadyEnrolled, privacy: .public))"
        )
        return outcome
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
        return try await coordinator.revoke(fingerprint)
    }

    /// Loads or creates this Mac's TLS identity.
    private func hostIdentity() throws -> (material: DeviceIdentityMaterial, secIdentity: SecIdentity) {
        if let cachedIdentity { return cachedIdentity }

        let material: DeviceIdentityMaterial
        if let existing = try identityStore.identity(forPairingID: Self.hostIdentitySlot) {
            material = existing
        } else {
            // A locked keychain throws above rather than returning nil, so
            // reaching here means the slot is genuinely empty — never "we could
            // not look", which would orphan every existing pairing.
            material = try DeviceIdentityMaterial.generate(commonName: "cmux-mac")
            try identityStore.save(material, forPairingID: Self.hostIdentitySlot)
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
