public import CMUXMobileCore
public import Network

/// Builds Network.framework TCP transports for host/port routes.
public struct CmxNetworkByteTransportFactory: CmxRouteAwareByteTransportFactory {
    public var supportedKinds: [CmxAttachTransportKind]
    public var maximumReceiveLength: Int
    public var connectTimeoutNanoseconds: UInt64
    private let tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing

    /// Fork (cmux Mochi): supplies DeviceLink's mutual-TLS options for a paired
    /// Mac. Taking a closure keeps this package free of DeviceLinkKit, so the
    /// transport holds no opinion about how identities are stored.
    ///
    /// A tailnet dial with no options available proceeds without TLS only for
    /// upstream's own authorization modes; an attach-ticket dial requires them,
    /// because the fork's pairing host is TLS-only and a plaintext dial could
    /// only reach something that is not our Mac.
    public var deviceLinkTLSOptions: (@Sendable () -> NWProtocolTLS.Options?)?

    public init(
        supportedKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds,
        // Fork (cmux Mochi): supplied at construction so a factory is never
        // briefly live without the TLS options its tailnet dials require.
        deviceLinkTLSOptions: (@Sendable () -> NWProtocolTLS.Options?)? = nil
    ) {
        self.supportedKinds = supportedKinds
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
        self.deviceLinkTLSOptions = deviceLinkTLSOptions
        tailscaleRouteAuthority = CmxSystemTailscaleRouteAuthority()
    }

    init(
        supportedKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds,
        tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing
    ) {
        self.supportedKinds = supportedKinds
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
        self.tailscaleRouteAuthority = tailscaleRouteAuthority
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try route.validate()
        guard supportedKinds.contains(route.kind) else {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .hostPort(host, port) = route.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        guard route.kind != .tailscale else {
            throw CmxNetworkByteTransportError.authorizationIntentRequired
        }
        return try CmxNetworkByteTransport(
            host: host,
            port: port,
            maximumReceiveLength: maximumReceiveLength,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds
        )
    }

    /// Preserves authorization intent so generic plaintext Tailscale routes
    /// fail closed and only an exact persisted compatibility grant can dial.
    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        let route = request.route
        try route.validate()
        guard supportedKinds.contains(route.kind) else {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .hostPort(host, port) = route.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        switch route.kind {
        case .tailscale:
            switch request.authorizationMode {
            case let .legacyTailscaleBearer(evidence):
                guard evidence.authorizes(
                    macDeviceID: request.expectedPeerDeviceID,
                    host: host,
                    port: port
                ) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
            case let .userAuthorizedTailscalePairing(authorization):
                // Anchored on the exact user-entered destination; any claimed
                // device identity is self-reported and grants nothing extra.
                guard authorization.authorizes(host: host, port: port) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
            case .attachTicket:
                // Fork (cmux Mochi): the ticket IS the credential, and the Mac
                // additionally refuses any non-tailnet connection, so no
                // separate route grant is required here.
                guard deviceLinkTLSOptions?() != nil else {
                    // Fail closed: the fork's pairing host is mutual-TLS only.
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
            case .stackBearer, .transportAdmission:
                // A generic Stack bearer never opts into the legacy risk.
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            return CmxPreparingTailscaleByteTransport(
                request: request,
                tailscaleRouteAuthority: tailscaleRouteAuthority,
                maximumReceiveLength: maximumReceiveLength,
                connectTimeoutNanoseconds: connectTimeoutNanoseconds,
                tlsOptions: deviceLinkTLSOptions?()
            )
        case .debugLoopback:
            switch request.authorizationMode {
            case .stackBearer:
                break
            case .attachTicket:
                // Fork (cmux Mochi): the ticket IS the credential, and this is
                // the route a simulator attaches over (see
                // MobileAttachTarget.simulatorInjection, which selects only
                // loopback routes). The tailscale branch above already accepts
                // `.attachTicket`; leaving it out here is what made every
                // simulator pairing fail with `unsupportedAuthorizationMode`.
                // Fail closed on TLS: the fork's listener applies
                // `deviceLinkListenerParameters` at every site, loopback included.
                guard deviceLinkTLSOptions?() != nil else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
            case .legacyTailscaleBearer, .userAuthorizedTailscalePairing, .transportAdmission:
                throw CmxNetworkByteTransportError.unsupportedAuthorizationMode(
                    request.authorizationMode
                )
            }
            guard CmxLoopbackHost().matches(route) else {
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            return try CmxNetworkByteTransport(
                host: host,
                port: port,
                maximumReceiveLength: maximumReceiveLength,
                connectTimeoutNanoseconds: connectTimeoutNanoseconds,
                tlsOptions: deviceLinkTLSOptions?()
            )
        case .iroh, .websocket:
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
    }
}
