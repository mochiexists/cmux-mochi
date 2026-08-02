public import Foundation

/// Persistence for the authorized-devices table.
///
/// Implementations back this with the platform keystore. The protocol exists so
/// the coordinator can be tested without one, and so the host app supplies its
/// own entitled, per-app-instance storage (two build variants on one Mac must
/// never read each other's tables).
public protocol AuthorizedDeviceStoring: Sendable {
    /// Reads the persisted table, or `nil` when nothing has been written.
    func load() async throws -> Data?
    /// Replaces the persisted table.
    func save(_ data: Data) async throws
}

/// Serializes every mutation of the authorized-devices table **and** the
/// admission decisions that read it.
///
/// One actor owns the table, ticket consumption, and the set of currently
/// admitted connections. That is what makes revocation linearizable: a revoke
/// is ordered either before an in-flight admission (which then fails its
/// fingerprint check) or after it (in which case the connection is already
/// indexed and gets closed). There is no window in which a just-verified
/// connection escapes an earlier revoke.
public actor DeviceLinkCoordinator {
    /// Caps and rate limits. Defaults are deliberately small: this is a
    /// personal fleet, and a large table is a symptom, not a feature.
    public struct Policy: Sendable {
        public var maximumDevices: Int
        public var minimumEnrollmentInterval: TimeInterval

        public init(maximumDevices: Int = 16, minimumEnrollmentInterval: TimeInterval = 60) {
            self.maximumDevices = maximumDevices
            self.minimumEnrollmentInterval = minimumEnrollmentInterval
        }

        public static let `default` = Policy()
    }

    private let store: any AuthorizedDeviceStoring
    private let policy: Policy
    private var table = AuthorizedDeviceTable()
    private var isLoaded = false
    private var lastEnrollmentAt: Date?

    /// Live enrollment tickets, keyed by secret. In memory only — a Mac restart
    /// invalidates outstanding QR codes, which is the correct behavior for a
    /// ten-minute capability.
    private var tickets: [String: EnrollmentTicket] = [:]

    /// Tickets whose redemption is mid-flight.
    ///
    /// Actors suspend at `await`, so persisting inside ``redeem(ticketSecret:fingerprint:rawLabel:now:)``
    /// releases the actor and lets a second caller observe a ticket that is
    /// about to be spent. Reserving the secret *before* the first suspension
    /// point is what makes single-use single-use; the reservation is released
    /// on failure so a retry still works.
    private var reservedTickets: Set<String> = []

    /// Fingerprints of connections currently admitted, with an opaque handle so
    /// the host can close them on revocation.
    private var admitted: [DeviceFingerprint: Set<UUID>] = [:]

    /// Called when revocation requires connections to be torn down. Set by the
    /// host after construction; the coordinator never imports the transport.
    private var closeConnections: (@Sendable (Set<UUID>) -> Void)?

    public init(store: any AuthorizedDeviceStoring, policy: Policy = .default) {
        self.store = store
        self.policy = policy
    }

    /// Installs the callback used to close connections during revocation.
    public func setConnectionCloser(_ closer: @escaping @Sendable (Set<UUID>) -> Void) {
        closeConnections = closer
    }

    /// Loads the table from the store.
    ///
    /// The host **must** await this before its listener reports ready, so no
    /// device can race a cold start into a spurious "unknown device" rejection.
    /// - Returns: `true` when persisted data was rejected as corrupt or
    ///   unversioned, so the caller can log it loudly.
    @discardableResult
    public func load() async throws -> Bool {
        let data = try await store.load()
        let (decoded, wasRejected) = AuthorizedDeviceTable.decode(data)
        table = decoded
        isLoaded = true
        return wasRejected
    }

    /// Loads on first use if the host has not already done so.
    ///
    /// Every reader goes through this, so a cold start cannot answer "unknown
    /// device" from an empty in-memory table while the real one sits unread on
    /// disk. The host still calls ``load()`` explicitly at startup to surface
    /// corruption early; this is the safety net, not the plan.
    private func ensureLoaded() async {
        guard !isLoaded else { return }
        _ = try? await load()
        isLoaded = true
    }

    /// All enrolled devices, newest first.
    public func devices() async -> [AuthorizedDevice] {
        await ensureLoaded()
        return table.devices.sorted { $0.createdAt > $1.createdAt }
    }

    /// Whether an enrollment window is currently open.
    public func hasOpenEnrollmentWindow(now: Date = Date()) -> Bool {
        pruneTickets(now: now)
        return !tickets.isEmpty
    }

    /// Mints and registers an enrollment ticket for a pairing QR.
    public func issueEnrollmentTicket(
        lifetime: TimeInterval = EnrollmentTicket.defaultLifetime,
        now: Date = Date()
    ) throws -> EnrollmentTicket {
        pruneTickets(now: now)
        let ticket = try EnrollmentTicket.mint(lifetime: lifetime, now: now)
        tickets[ticket.secret] = ticket
        return ticket
    }

    /// Whether a fingerprint is authorized right now.
    ///
    /// This is the TLS verify block's question. It reads the actor's state, so
    /// it cannot observe a table mid-mutation.
    public func isAuthorized(_ fingerprint: DeviceFingerprint) async -> Bool {
        await ensureLoaded()
        return table.devices.contains { $0.fingerprint == fingerprint }
    }

    /// Redeems a ticket, enrolling the presented fingerprint.
    ///
    /// Ordering is the point: validate → **persist** → consume. A persistence
    /// failure leaves the ticket redeemable so the device can retry, and a
    /// response lost after a successful commit is harmless because re-enrolling
    /// an already-authorized fingerprint is idempotent.
    ///
    /// - Parameters:
    ///   - ticketSecret: The secret carried in the QR.
    ///   - fingerprint: The client certificate's fingerprint, taken from the
    ///     live TLS handshake — never from the request body.
    ///   - rawLabel: Operator-facing name, normalized before storage.
    ///   - now: Injected clock for tests.
    /// - Returns: The stored row and whether it already existed.
    public func redeem(
        ticketSecret: String,
        fingerprint: DeviceFingerprint,
        rawLabel: String,
        now: Date = Date()
    ) async throws -> EnrollmentOutcome {
        pruneTickets(now: now)

        // An already-enrolled device re-presenting a ticket is a retry, not a
        // new enrollment: refresh its label and leave quota and ticket alone.
        if let existingIndex = table.devices.firstIndex(where: { $0.fingerprint == fingerprint }) {
            table.devices[existingIndex].label = DeviceLabel.normalized(rawLabel)
            table.devices[existingIndex].lastSeenAt = now
            let snapshot = table
            try await persist(snapshot)
            tickets[ticketSecret] = nil
            return EnrollmentOutcome(device: table.devices[existingIndex], wasAlreadyEnrolled: true)
        }

        guard let ticket = tickets[ticketSecret],
              ticket.isRedeemable(at: now),
              !reservedTickets.contains(ticketSecret)
        else {
            throw EnrollmentError.ticketUnusable
        }
        if let lastEnrollmentAt, now.timeIntervalSince(lastEnrollmentAt) < policy.minimumEnrollmentInterval {
            throw EnrollmentError.throttled
        }
        guard table.devices.count < policy.maximumDevices else {
            throw EnrollmentError.deviceQuotaExceeded
        }

        // Reserve before the first suspension point (see `reservedTickets`).
        reservedTickets.insert(ticketSecret)

        let device = AuthorizedDevice(
            fingerprint: fingerprint,
            label: DeviceLabel.normalized(rawLabel),
            createdAt: now,
            lastSeenAt: now
        )
        var proposed = table
        proposed.devices.append(device)
        do {
            try await persist(proposed)
        } catch {
            // Nothing was written, so hand the ticket back for a retry.
            reservedTickets.remove(ticketSecret)
            throw error
        }

        // Persisted: only now is the ticket spent and the throttle armed.
        table = proposed
        tickets[ticketSecret] = nil
        reservedTickets.remove(ticketSecret)
        lastEnrollmentAt = now
        return EnrollmentOutcome(device: device, wasAlreadyEnrolled: false)
    }

    /// Records that a connection has been admitted for a fingerprint.
    ///
    /// Returns `false` when the device was revoked between the handshake and
    /// this call — the caller must then drop the connection. This is the second
    /// half of linearizable revocation.
    public func registerAdmission(_ fingerprint: DeviceFingerprint, connectionID: UUID, now: Date = Date()) async -> Bool {
        guard let index = table.devices.firstIndex(where: { $0.fingerprint == fingerprint }) else {
            return false
        }
        table.devices[index].lastSeenAt = now
        admitted[fingerprint, default: []].insert(connectionID)
        let snapshot = table
        try? await persist(snapshot)
        return true
    }

    /// Forgets a closed connection.
    public func unregisterAdmission(_ fingerprint: DeviceFingerprint, connectionID: UUID) {
        admitted[fingerprint]?.remove(connectionID)
        if admitted[fingerprint]?.isEmpty == true { admitted[fingerprint] = nil }
    }

    /// Revokes a device and closes everything it currently holds open.
    /// - Returns: `true` when a row was removed.
    @discardableResult
    public func revoke(_ fingerprint: DeviceFingerprint) async throws -> Bool {
        guard table.devices.contains(where: { $0.fingerprint == fingerprint }) else { return false }
        var proposed = table
        proposed.devices.removeAll { $0.fingerprint == fingerprint }
        try await persist(proposed)
        table = proposed

        if let connections = admitted.removeValue(forKey: fingerprint), !connections.isEmpty {
            closeConnections?(connections)
        }
        return true
    }

    private func persist(_ proposed: AuthorizedDeviceTable) async throws {
        do {
            try await store.save(try proposed.encoded())
        } catch {
            throw EnrollmentError.persistenceFailed
        }
    }

    private func pruneTickets(now: Date) {
        tickets = tickets.filter { $0.value.isRedeemable(at: now) }
    }
}
