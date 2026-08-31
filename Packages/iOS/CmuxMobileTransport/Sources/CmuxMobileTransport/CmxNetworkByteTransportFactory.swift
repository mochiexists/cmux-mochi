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
            let tlsOptions: NWProtocolTLS.Options?
            switch request.authorizationMode {
            case let .legacyTailscaleBearer(evidence):
                guard evidence.authorizes(
                    macDeviceID: request.expectedPeerDeviceID,
                    host: host,
                    port: port
                ) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
                tlsOptions = nil
            case let .userAuthorizedTailscalePairing(authorization):
                // Anchored on the exact user-entered destination; any claimed
                // device identity is self-reported and grants nothing extra.
                guard authorization.authorizes(host: host, port: port) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
                tlsOptions = nil
            case .attachTicket:
                // Fork (cmux Mochi): the ticket IS the credential, and the Mac
                // additionally refuses any non-tailnet connection, so no
                // separate route grant is required here.
                guard let resolvedTLSOptions = deviceLinkTLSOptions?(request) else {
                    // Fail closed: the fork's pairing host is mutual-TLS only.
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
                tlsOptions = resolvedTLSOptions
            case .transportAdmission:
                // Fork (cmux Mochi): a DeviceLink pairing admits itself through
                // the mutual-TLS handshake -- this device's key against the
                // Mac's pinned fingerprint. That is strictly stronger evidence
                // than the bearer grants above, so it needs no separate route
                // authorization. Fail closed when there is no identity to offer.
                guard let resolvedTLSOptions = deviceLinkTLSOptions?(request) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
                tlsOptions = resolvedTLSOptions
            case .stackBearer:
                // A generic Stack bearer never opts into the legacy risk.
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
            let tlsOptions: NWProtocolTLS.Options?
            switch request.authorizationMode {
            case .stackBearer:
                tlsOptions = nil
            case .attachTicket:
                // Fork (cmux Mochi): the ticket IS the credential, and this is
                // the route a simulator attaches over (see
                // MobileAttachTarget.simulatorInjection, which selects only
                // loopback routes). The tailscale branch above already accepts
                // `.attachTicket`; leaving it out here is what made every
                // simulator pairing fail with `unsupportedAuthorizationMode`.
                // Fail closed on TLS: the fork's listener applies
                // `deviceLinkListenerParameters` at every site, loopback included.
                guard let resolvedTLSOptions = deviceLinkTLSOptions?(request) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
                tlsOptions = resolvedTLSOptions
            case .transportAdmission:
                // Same reasoning as the tailscale branch: a DeviceLink pairing
                // admits itself over mutual TLS. This is the route a paired
                // simulator reconnects over, since it shares the Mac's network
                // stack and cannot dial the Mac's own tailnet address.
                guard let resolvedTLSOptions = deviceLinkTLSOptions?(request) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
                tlsOptions = resolvedTLSOptions
            case .legacyTailscaleBearer, .userAuthorizedTailscalePairing:
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
                tlsOptions: tlsOptions
            )
        case .iroh, .websocket:
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
    }
}
