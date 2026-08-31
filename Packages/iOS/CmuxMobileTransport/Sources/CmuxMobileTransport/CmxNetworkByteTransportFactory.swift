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
    /// Network routes are never admitted without these options: the fork's
    /// pairing host is mutual-TLS-only, and a plaintext dial cannot prove it
    /// reached the paired Mac.
    public var deviceLinkTLSOptions:
        (@Sendable (CmxByteTransportRequest) -> NWProtocolTLS.Options?)?

    public init(
        supportedKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds,
        // Fork (cmux Mochi): supplied at construction so a factory is never
        // briefly live without the TLS options its tailnet dials require.
        deviceLinkTLSOptions:
            (@Sendable (CmxByteTransportRequest) -> NWProtocolTLS.Options?)? = nil
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

    /// Builds only mutually authenticated DeviceLink network routes.
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
            guard let tlsOptions = deviceLinkTLSOptions?(request) else {
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            return CmxPreparingTailscaleByteTransport(
                request: request,
                tailscaleRouteAuthority: tailscaleRouteAuthority,
                maximumReceiveLength: maximumReceiveLength,
                connectTimeoutNanoseconds: connectTimeoutNanoseconds,
                tlsOptions: tlsOptions
            )
        case .debugLoopback:
            // Simulator pairings share the Mac network stack, but the listener
            // is still mutual-TLS-only. Loopback is not an authentication
            // exception.
            guard let tlsOptions = deviceLinkTLSOptions?(request) else {
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            guard CmxLoopbackHost().matches(route) else {
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            return try CmxNetworkByteTransport(
                host: host,
                port: port,
                maximumReceiveLength: maximumReceiveLength,
                connectTimeoutNanoseconds: connectTimeoutNanoseconds,
                tlsOptions: tlsOptions
            )
        case .iroh, .websocket:
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
    }
}
