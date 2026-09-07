internal import CMUXMobileCore
import Foundation
import Network

/// Defers the actor-isolated route proof until `connect()` while preserving the
/// synchronous transport-factory contract. The proven interface is set on
/// `NWParameters` before Network.framework starts the connection.
/// Resolves a hostname to numeric addresses, in preference order.
///
/// Injected so the MagicDNS path is testable without a live tailnet.
typealias CmxTailscaleHostResolving = @Sendable (String) async throws -> [String]

actor CmxPreparingTailscaleByteTransport: CmxByteTransport {
    private let request: CmxByteTransportRequest
    private let tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing
    private let maximumReceiveLength: Int
    private let connectTimeoutNanoseconds: UInt64
    private let tlsOptions: NWProtocolTLS.Options?
    private let resolveHost: CmxTailscaleHostResolving
    private var preparationTask: Task<any CmxByteTransport, any Error>?
    private var transport: (any CmxByteTransport)?
    private var isClosed = false

    init(
        request: CmxByteTransportRequest,
        tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing,
        maximumReceiveLength: Int,
        connectTimeoutNanoseconds: UInt64,
        tlsOptions: NWProtocolTLS.Options? = nil,
        resolveHost: @escaping CmxTailscaleHostResolving = CmxSystemHostResolver.addresses(for:)
    ) {
        self.request = request
        self.tailscaleRouteAuthority = tailscaleRouteAuthority
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
        self.tlsOptions = tlsOptions
        self.resolveHost = resolveHost
    }

    /// Rewrites a MagicDNS route to the tailnet address it names.
    ///
    /// The Mac publishes `<host>.<tailnet>.ts.net` alongside its numeric routes
    /// because that name is the only locator that survives a tailnet IP change.
    /// The route proof requires a numeric peer, so without this the durable
    /// route is the one route that can never be dialed — invisible while the
    /// numeric routes still work, and the whole pairing once they go stale.
    ///
    /// Resolution does not weaken the proof: the resolved address still has to
    /// pass the same tailnet-range, path, and interface checks as any other, and
    /// DeviceLink TLS pins the Mac's certificate rather than a hostname.
    static func requestResolvingMagicDNS(
        _ request: CmxByteTransportRequest,
        resolveHost: CmxTailscaleHostResolving
    ) async throws -> CmxByteTransportRequest {
        guard case let .hostPort(host, port) = request.route.endpoint,
              CmxTailscaleIPAddress(host) == nil else {
            return request
        }
        let candidates = (try? await resolveHost(host)) ?? []
        guard let resolved = candidates.first(where: { candidate in
            CmxTailscaleIPAddress(candidate)?.isTailscalePeerAddress == true
        }) else {
            // A name that resolves to nothing inside the tailnet is not a peer
            // this transport may dial; report it as the same non-numeric peer
            // the proof would have rejected.
            throw CmxTailscaleRouteProofError.nonNumericPeer
        }
        return CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: request.route.id,
                kind: request.route.kind,
                endpoint: .hostPort(host: resolved, port: port),
                priority: request.route.priority
            ),
            expectedPeerDeviceID: request.expectedPeerDeviceID,
            expectedPeerInstanceTag: request.expectedPeerInstanceTag,
            authorizationMode: request.authorizationMode,
            sessionPurpose: request.sessionPurpose
        )
    }

    func connect() async throws {
        let transport = try await preparedTransport()
        try await transport.connect()
    }

    func receive() async throws -> Data? {
        guard let transport else {
            throw isClosed
                ? CmxNetworkByteTransportError.alreadyClosed
                : CmxNetworkByteTransportError.notConnected
        }
        return try await transport.receive()
    }

    func send(_ data: Data) async throws {
        guard let transport else {
            throw isClosed
                ? CmxNetworkByteTransportError.alreadyClosed
                : CmxNetworkByteTransportError.notConnected
        }
        try await transport.send(data)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        preparationTask?.cancel()
        if let transport {
            await transport.close()
        }
    }

    private func preparedTransport() async throws -> any CmxByteTransport {
        guard !isClosed else {
            throw CmxNetworkByteTransportError.alreadyClosed
        }
        if let transport {
            return transport
        }

        let task: Task<any CmxByteTransport, any Error>
        if let preparationTask {
            task = preparationTask
        } else {
            let request = request
            let authority = tailscaleRouteAuthority
            let maximumReceiveLength = maximumReceiveLength
            let connectTimeoutNanoseconds = connectTimeoutNanoseconds
            task = Task {
                do {
                    let request = try await Self.requestResolvingMagicDNS(
                        request,
                        resolveHost: resolveHost
                    )
                    let prepared = try await authority.prepare(request: request)
                    try Task.checkCancellation()
                    return try CmxNetworkByteTransport(
                        request: request,
                        preparedTailscaleRoute: prepared,
                        tailscaleRouteAuthority: authority,
                        maximumReceiveLength: maximumReceiveLength,
                        connectTimeoutNanoseconds: connectTimeoutNanoseconds,
                        tlsOptions: tlsOptions
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    #if DEBUG
                    // Flattening every preparation failure into one case makes a
                    // route proof that failed for a *nameable* reason (wrong
                    // peer range, no Tailscale interface, unsatisfied path)
                    // indistinguishable from a missing authorization. Surface
                    // the reason in dev builds; release keeps the single case so
                    // no caller has to learn a new one.
                    if error is CmxTailscaleRouteProofError { throw error }
                    #endif
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
            }
            preparationTask = task
        }

        do {
            let preparedTransport = try await task.value
            guard !isClosed else {
                await preparedTransport.close()
                throw CmxNetworkByteTransportError.alreadyClosed
            }
            transport = preparedTransport
            preparationTask = nil
            return preparedTransport
        } catch {
            preparationTask = nil
            throw error
        }
    }
}
