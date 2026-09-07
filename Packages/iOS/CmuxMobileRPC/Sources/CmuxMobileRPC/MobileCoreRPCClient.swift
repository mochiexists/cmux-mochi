public import CMUXMobileCore
internal import CmuxMobileShellModel
internal import CmuxMobileSupport
public import Foundation
internal import os

/// A multiplexed RPC client over a single persistent transport to a paired Mac.
///
/// All stored properties are immutable `let`s of `Sendable` types (the session
/// is an actor), so this is genuinely `Sendable` without opting out of checking.
public final class MobileCoreRPCClient: MobileSyncing, Sendable {
    private static let independentEventPreparationTimeoutNanoseconds: UInt64 = 3_000_000_000
    private let runtime: any MobileSyncRuntime
    private let route: CmxAttachRoute
    private let ticket: CmxAttachTicket
    private let transportRequest: CmxByteTransportRequest
    /// The attach ticket this client uses to authorize RPC requests.
    public var attachTicket: CmxAttachTicket { ticket }
    // `internal` (not `private`) so `@testable import` can observe session
    // queue state from tests, instead of exposing a debug hook in production.
    let session: MobileCoreRPCSession
    private let lifecycleGate: MobileRPCClientLifecycleGate

    /// Create a client bound to one route + attach ticket.
    /// - Parameters:
    ///   - runtime: The DI runtime supplying transport factory, token provider, timeouts, clock.
    ///   - route: The attach route this client connects over.
    ///   - ticket: The attach ticket authorizing requests.
    ///   - transportConnectObserver: Optional synchronous sink for privacy-safe
    ///     transport dial lifecycle events. The observer must return immediately.
    ///   - retiresOnPersistentEventTransportInvalidation: Whether an unexpected
    ///     failure of an event-owning transport permanently retires this client
    ///     so its external owner can install a fresh connection generation.
    public init(
        runtime: any MobileSyncRuntime,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        expectedPeerInstanceTag: String? = nil,
        connectAttemptRegistry: MobileRPCConnectAttemptRegistry = MobileRPCConnectAttemptRegistry(),
        abandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000,
        lateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000,
        transportConnectObserver: (@Sendable (MobileRPCTransportConnectEvent) -> Void)? = nil,
        sessionPurpose: CmxTransportSessionPurpose = .foregroundControl,
        retiresOnPersistentEventTransportInvalidation: Bool = false
    ) {
        self.runtime = runtime
        self.route = route
        self.ticket = ticket
        // Every Mochi client is admitted by its transport. Iroh authenticates
        // the peer in its stream handshake; network routes require an exact
        // DeviceLink mutual-TLS identity in the transport factory. The RPC
        // layer never chooses or serializes a Stack/account credential.
        let transportRequest = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: ticket.macDeviceID,
            expectedPeerInstanceTag: expectedPeerInstanceTag,
            authorizationMode: .transportAdmission,
            sessionPurpose: sessionPurpose
        )
        self.transportRequest = transportRequest
        let lifecycleGate = MobileRPCClientLifecycleGate()
        self.lifecycleGate = lifecycleGate
        let independentEventFactory: MobileCoreRPCSession.IndependentEventByteStreamFactory?
        if route.kind == .iroh,
           let provider = runtime.independentEventByteStreamProvider {
            independentEventFactory = {
                let admission = try lifecycleGate.beginIndependentEventAdmission()
                let stream = try await provider(transportRequest)
                return try await lifecycleGate.finishIndependentEventAdmission(
                    admission,
                    stream: stream
                )
            }
        } else {
            independentEventFactory = nil
        }
        let persistentEventTransportInvalidationHook:
            MobileCoreRPCSession.PersistentEventTransportInvalidationHook?
        if retiresOnPersistentEventTransportInvalidation {
            persistentEventTransportInvalidationHook = {
                lifecycleGate.retire()
            }
        } else {
            persistentEventTransportInvalidationHook = nil
        }
        self.session = MobileCoreRPCSession(
            connectAttemptKey: MobileRPCConnectAttemptKey(
                route: route
            ),
            connectAttemptRegistry: connectAttemptRegistry,
            abandonedConnectCleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateAbandonedConnectCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds,
            makeTransport: { [runtime, transportRequest, lifecycleGate] in
                try lifecycleGate.makeTransport {
                    try runtime.transportFactory.makeTransport(for: transportRequest)
                }
            },
            makeIndependentEventByteStream: independentEventFactory,
            diagnosticTransport: route.kind.diagnosticTransportKind,
            transportConnectObserver: transportConnectObserver,
            initialTransportSessionPurpose: sessionPurpose,
            persistentEventTransportInvalidationHook:
                persistentEventTransportInvalidationHook,
            transportAdmissionPreflight: {
                let preflight = try lifecycleGate
                    .captureTransportAdmissionPreflight()
                return {
                    lifecycleGate.isTransportAdmissionPreflightCurrent(
                        preflight
                    )
                }
            }
        )
    }

    /// Tear down the persistent transport (called when the client is
    /// replaced or the user signs out).
    public func disconnect() async {
        retire()
        await session.tearDown(error: .connectionClosed)
    }

    /// Retire this client and await both its installed transport close and any
    /// transport factory admission that raced retirement. A cancellation-
    /// ignoring abandoned dial is handed to the shared route registry after a
    /// bounded cleanup interval. Installed transports retain that same global
    /// lease until their exact close task finishes. The registry permits one
    /// recovery dial and blocks further route admission while two physical
    /// cleanups remain unresolved.
    public func disconnectAndWaitForTransportDrain() async {
        retire()
        await session.tearDown(error: .connectionClosed)
        async let sessionDrain: Void = session.waitForTransportDrain()
        async let admissionDrain: Void =
            lifecycleGate.waitForRetiredTransportDisposals()
        _ = await (sessionDrain, admissionDrain)
    }

    /// Returns whether `otherRoute` competes for this client's exact physical
    /// connection lease. Shell handoffs use this before the target reports its
    /// logical Mac identity, so anonymous and refreshed Iroh routes still
    /// release an existing same-peer owner before dialing.
    public func sharesPhysicalTransportRoute(
        with otherRoute: CmxAttachRoute
    ) -> Bool {
        MobileRPCConnectAttemptKey(route: route)
            == MobileRPCConnectAttemptKey(route: otherRoute)
    }

    /// Synchronously prevent this client from allocating another transport.
    /// Shell ownership changes call this before scheduling actor-isolated
    /// teardown, closing the window where an already-queued RPC could reopen a
    /// client that is no longer authoritative.
    public func retire() {
        lifecycleGate.retire()
    }

    /// Reclassifies this client's live transport when shell ownership moves
    /// between the focused render role and the warm control pool.
    public func updateTransportSessionPurpose(
        _ purpose: CmxTransportSessionPurpose
    ) async {
        await session.updateTransportSessionPurpose(purpose)
    }

    /// Subscribe to server-pushed events. Returns a stream of envelopes
    /// matching any of the requested topics. Cancel by terminating iteration.
    public func subscribe(to topics: Set<String>) async -> AsyncStream<MobileEventEnvelope> {
        await session.addEventListener(topics: topics).stream
    }

    /// Starts the optional Iroh server-event lane before advertising support to
    /// the host. Returns `false` on unsupported routes or setup failure so the
    /// caller can retain control-stream event delivery.
    public func prepareIndependentServerEvents() async -> Bool {
        await session.prepareIndependentServerEvents()
    }

    /// Opens an artifact lane bound to this client's immutable admitted route.
    public func openArtifactLane(
        resourceID: String,
        offset: UInt64
    ) async throws -> any MobileArtifactLaneConnection {
        guard route.kind == .iroh,
              let provider = runtime.artifactLaneProvider else {
            throw MobileShellConnectionError.connectionClosed
        }
        let admission = try lifecycleGate.beginArtifactLaneAdmission()
        let connection = try await provider(
            transportRequest,
            resourceID,
            offset
        )
        return try await lifecycleGate.finishArtifactLaneAdmission(
            admission,
            connection: connection
        )
    }

    /// Build a JSON-RPC request frame with the given method and params.
    /// - Parameters:
    ///   - method: The RPC method name.
    ///   - params: The request parameters.
    ///   - id: The request id (defaults to a fresh UUID). Must be unique per
    ///     logical request: the session does not tombstone the ids of
    ///     cancelled or timed-out requests on a preserved transport, so
    ///     reusing an id for a retry lets the original request's late
    ///     response settle the retry.
    /// - Returns: The encoded request data.
    /// - Throws: A serialization error if the params are not JSON-encodable.
    public static func requestData(
        method: String,
        params: [String: Any] = [:],
        id: String = UUID().uuidString
    ) throws -> Data {
        let request: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        return try JSONSerialization.data(withJSONObject: request)
    }

    /// Sends one JSON-RPC request over the paired Mac connection.
    ///
    /// The optional timeout is a hard end-to-end deadline for connection setup
    /// and response wait, not a per-subphase timeout.
    public func sendRequest(_ requestData: Data, timeoutNanoseconds: UInt64? = nil) async throws -> Data {
        try await sendRequestOperation(
            requestData,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    /// Enqueues one request on the authenticated transport and returns before
    /// its response arrives.
    ///
    /// Sequential calls from one caller enqueue transport writes in call order.
    ///
    /// - Parameters:
    ///   - requestData: The encoded JSON-RPC request.
    ///   - timeoutNanoseconds: An optional end-to-end request deadline.
    /// - Returns: A handle that separately awaits the response settlement.
    /// - Throws: An encoding, connection, or enqueue error.
    public func sendRequestPipelined(
        _ requestData: Data,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> MobileCoreRPCPipelinedRequest {
        let deadline = RPCRequestDeadline(
            timeoutNanoseconds: timeoutNanoseconds
                ?? runtime.rpcRequestTimeoutNanoseconds
        )
        let (id, augmented) = try Self.requestWithGuaranteedID(requestData)
        let sanitized = try Self.requestDataWithoutCallerAuth(augmented)
        try Task.checkCancellation()
        try await session.beginSend(
            payload: sanitized,
            requestID: id,
            deadlineUptimeNanoseconds: deadline.uptimeNanoseconds
        )
        return MobileCoreRPCPipelinedRequest(
            requestID: id,
            session: session
        )
    }

    /// Sends a request and then reads host identity over the same authenticated
    /// transport. No application-layer credential crosses the connection.
    public func sendRequestAndAuthenticatedHostStatus(
        _ requestData: Data,
        timeoutNanoseconds: UInt64? = nil,
        hostStatusTimeoutNanoseconds: @Sendable () -> UInt64? = { nil }
    ) async throws -> (response: Data, hostStatusResponse: Data) {
        guard let request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              Self.requestRequiresAuth(request) else {
            throw MobileShellConnectionError.invalidResponse
        }
        let response = try await sendRequestOperation(
            requestData,
            timeoutNanoseconds: timeoutNanoseconds
        )
        let hostStatusTimeout = hostStatusTimeoutNanoseconds()
        if hostStatusTimeout == 0 {
            throw MobileShellConnectionError.requestTimedOut
        }
        let hostStatusResponse = try await sendRequestOperation(
            Self.requestData(method: "mobile.host.status", params: [:]),
            timeoutNanoseconds: hostStatusTimeout
        )
        return (response, hostStatusResponse)
    }

    private func sendRequestOperation(
        _ requestData: Data,
        timeoutNanoseconds: UInt64?
    ) async throws -> Data {
        let deadline = RPCRequestDeadline(
            timeoutNanoseconds: timeoutNanoseconds ?? runtime.rpcRequestTimeoutNanoseconds
        )
        let preparedRequest = await requestAdvertisingIndependentEvents(
            requestData,
            deadline: deadline
        )
        return try await sendRequestOnAuthenticatedTransport(
            preparedRequest,
            deadline: deadline
        )
    }

    /// Adds the rolling-compatible opt-in only after the Iroh accept owner is
    /// installed. Older hosts ignore the field and continue control delivery.
    private func requestAdvertisingIndependentEvents(
        _ requestData: Data,
        deadline: RPCRequestDeadline
    ) async -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              request["method"] as? String == "mobile.events.subscribe",
              var params = request["params"] as? [String: Any],
              params["event_transport"] == nil,
              let streamID = params["stream_id"] as? String,
              let remaining = try? deadline.remainingNanoseconds() else {
            return requestData
        }
        let preparationTimeout = min(
            remaining,
            Self.independentEventPreparationTimeoutNanoseconds
        )
        guard await session.prepareIndependentServerEvents(
            forSubscriptionStreamID: streamID,
            timeoutNanoseconds: preparationTimeout
        ) else {
            return requestData
        }
        params["event_transport"] = "iroh_server_events_v1"
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? requestData
    }

    private func sendRequestOnAuthenticatedTransport(
        _ requestData: Data,
        deadline: RPCRequestDeadline
    ) async throws -> Data {
        // Multiplexed over a persistent transport: each request gets a unique
        // id, the session's reader task routes the response back here. No
        // connect/close per RPC, no head-of-line blocking between calls.
        let (id, augmented) = try Self.requestWithGuaranteedID(requestData)
        let sanitized = try Self.requestDataWithoutCallerAuth(augmented)
        try Task.checkCancellation()
        return try await session.send(
            payload: sanitized,
            requestID: id,
            deadlineUptimeNanoseconds: deadline.uptimeNanoseconds
        )
    }

    private static func requestWithGuaranteedID(
        _ requestData: Data
    ) throws -> (String, Data) {
        guard var dict = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            throw MobileShellConnectionError.invalidResponse
        }
        let id: String
        if let existing = dict["id"] as? String, !existing.isEmpty {
            id = existing
        } else {
            id = UUID().uuidString
            dict["id"] = id
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return (id, data)
    }

    /// Removes any application-layer credential supplied by a caller. Peer
    /// authorization belongs exclusively to the immutable transport request.
    private static func requestDataWithoutCallerAuth(
        _ requestData: Data
    ) throws -> Data {
        guard var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return requestData
        }
        request.removeValue(forKey: "auth")
        return try JSONSerialization.data(withJSONObject: request)
    }

    private static func requestRequiresAuth(_ request: [String: Any]) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The host probe is the only method unsuitable as the first half of the
        // request-then-identity verification helper.
        return method != "mobile.host.status"
    }

}
