/// The authenticated transport boundary established before application bytes
/// are sent.
public enum CmxTransportAuthorizationMode: Equatable, Sendable {
    /// The transport handshake admitted the exact peer. Application requests
    /// never carry an account bearer or attach token in the Mochi fork.
    case transportAdmission
}

/// Route plus peer intent required to build a transport without substitution.
public struct CmxByteTransportRequest: Equatable, Sendable {
    /// The route the transport must dial without substituting another peer.
    public let route: CmxAttachRoute
    /// The authenticated peer device expected on the route, when known.
    public let expectedPeerDeviceID: String?
    /// The exact build-scoped Mac instance expected on the route, when known.
    public let expectedPeerInstanceTag: String?
    /// The authorization evidence permitted on the transport.
    public let authorizationMode: CmxTransportAuthorizationMode
    /// The local owner whose network path this request represents.
    public let sessionPurpose: CmxTransportSessionPurpose

    /// Creates a route-bound transport request with explicit peer authority.
    public init(
        route: CmxAttachRoute,
        expectedPeerDeviceID: String?,
        expectedPeerInstanceTag: String? = nil,
        authorizationMode: CmxTransportAuthorizationMode,
        sessionPurpose: CmxTransportSessionPurpose = .foregroundControl
    ) {
        self.route = route
        self.expectedPeerDeviceID = expectedPeerDeviceID
        self.expectedPeerInstanceTag = expectedPeerInstanceTag
        self.authorizationMode = authorizationMode
        self.sessionPurpose = sessionPurpose
    }

    /// Returns the same route and authority with a different local owner role.
    public func withSessionPurpose(
        _ sessionPurpose: CmxTransportSessionPurpose
    ) -> Self {
        Self(
            route: route,
            expectedPeerDeviceID: expectedPeerDeviceID,
            expectedPeerInstanceTag: expectedPeerInstanceTag,
            authorizationMode: authorizationMode,
            sessionPurpose: sessionPurpose
        )
    }
}
