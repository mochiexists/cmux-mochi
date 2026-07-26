/// The authorization already established before application bytes are sent.
public enum CmxTransportAuthorizationMode: Equatable, Sendable {
    /// RPC requests must add a Stack bearer on an approved transport.
    case stackBearer
    /// The transport handshake admitted this exact peer and account binding.
    case transportAdmission
    /// Fork (cmux Mochi): RPC requests carry ONLY a short-lived attach token
    /// minted by, and scoped to, one Mac — never an account bearer.
    ///
    /// This exists to distinguish "no account credential is at risk on this
    /// connection" from ``stackBearer``. Upstream refuses plaintext Tailscale
    /// routes outright (`CmxNetworkByteTransportFactory`) because
    /// Network.framework cannot prove a generic packet tunnel really is
    /// Tailscale, so a Stack bearer sent over it could reach an impostor. That
    /// reasoning is sound for an account credential and does not transfer to an
    /// attach token: it authorizes exactly one Mac, expires in an hour, is
    /// revoked when the ticket is dropped, and the Mac host independently
    /// refuses any connection that is not tailnet-to-tailnet
    /// (`MobileHostService.isTailnetConnection`). Worst case for a spoofed
    /// tunnel is a token that opens nothing but the Mac that issued it.
    case attachTicket
}

/// Route plus peer intent required to build a transport without substitution.
public struct CmxByteTransportRequest: Equatable, Sendable {
    public let route: CmxAttachRoute
    public let expectedPeerDeviceID: String?
    public let authorizationMode: CmxTransportAuthorizationMode

    public init(
        route: CmxAttachRoute,
        expectedPeerDeviceID: String?,
        authorizationMode: CmxTransportAuthorizationMode
    ) {
        self.route = route
        self.expectedPeerDeviceID = expectedPeerDeviceID
        self.authorizationMode = authorizationMode
    }
}
