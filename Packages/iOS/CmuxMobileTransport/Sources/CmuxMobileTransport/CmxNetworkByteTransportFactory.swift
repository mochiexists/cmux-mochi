public import CMUXMobileCore
public import Network

/// Builds Network.framework TCP transports for host/port routes.
public struct CmxNetworkByteTransportFactory: CmxRouteAwareByteTransportFactory {
    public var supportedKinds: [CmxAttachTransportKind]
    public var maximumReceiveLength: Int
    public var connectTimeoutNanoseconds: UInt64
    /// Fork (cmux Mochi): supplies DeviceLink's mutual-TLS options for a paired
    /// Mac. The factory stays free of DeviceLinkKit by taking a closure, so the
    /// transport package keeps no opinion about how identities are stored.
    ///
    /// A tailnet route with no options available fails closed: the pairing host
    /// is TLS-only, so a plaintext dial could only ever be a misconfiguration or
    /// an attempt to reach something that is not our Mac.
    public var deviceLinkTLSOptions: (@Sendable () -> NWProtocolTLS.Options?)?

    public init(
        supportedKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds,
        deviceLinkTLSOptions: (@Sendable () -> NWProtocolTLS.Options?)? = nil
    ) {
        self.supportedKinds = supportedKinds
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
        self.deviceLinkTLSOptions = deviceLinkTLSOptions
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

    /// Preserves authorization intent so plaintext routes fail closed unless
    /// they are local simulator loopback.
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
        guard request.authorizationMode == .stackBearer
                || request.authorizationMode == .attachTicket
                || request.authorizationMode == .transportAdmission else {
            throw CmxNetworkByteTransportError.unsupportedAuthorizationMode(
                request.authorizationMode
            )
        }

        switch route.kind {
        case .tailscale:
            // Network.framework exposes only a generic packet-tunnel interface.
            // It cannot prove that the tunnel belongs to Tailscale's authenticated
            // control plane, so plaintext TCP must never carry a Stack bearer.
            //
            // Fork (cmux Mochi): an attach-ticket request carries no account
            // bearer, so that reasoning does not apply — see
            // ``CmxTransportAuthorizationMode/attachTicket``. Stack-bearer
            // requests keep failing closed exactly as upstream.
            // `.transportAdmission` here means DeviceLink: mutual TLS with the
            // Mac's key pinned, which is a stronger guarantee than the attach
            // ticket this check was written for.
            guard request.authorizationMode == .attachTicket
                    || request.authorizationMode == .transportAdmission else {
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            // Fork (cmux Mochi): the pairing host requires a client certificate,
            // so a tailnet dial without DeviceLink options cannot succeed — fail
            // here rather than opening a socket that can only be refused.
            guard let tlsOptions = deviceLinkTLSOptions?() else {
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            return try CmxNetworkByteTransport(
                host: host,
                port: port,
                maximumReceiveLength: maximumReceiveLength,
                connectTimeoutNanoseconds: connectTimeoutNanoseconds,
                tlsOptions: tlsOptions
            )
        case .debugLoopback:
            guard CmxLoopbackHost().matches(route) else {
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            // Fork (cmux Mochi): the pairing host is TLS-only on every
            // interface, so a loopback dial needs the same DeviceLink options a
            // tailnet dial does. Dialing this one in plaintext is invisible
            // until the handshake never completes.
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
