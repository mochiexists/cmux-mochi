import Foundation

/// Encodes the full-key v1 pairing payload required by released iOS clients
/// that predate the compact ticket and bare-route grammars.
public struct CmxLegacyPrivateNetworkPairingCode: Sendable {
    /// The compatibility payload is non-authorizing, so its synthetic expiry
    /// only prevents historical decoders from rejecting a displayed code.
    private static let compatibilityExpiry = Date(timeIntervalSince1970: 4_102_444_800)

    /// Creates the stateless compatibility encoder.
    public init() {}

    /// Returns a tokenless Tailscale-only v1 pairing URL, or `nil` when the
    /// ticket has no Tailscale route to disclose.
    public func encode(_ ticket: CmxAttachTicket) throws -> URL? {
        let tailscaleRoutes = ticket.routes.filter { $0.kind == .tailscale }
        guard !tailscaleRoutes.isEmpty else { return nil }

        let legacyTicket = try CmxAttachTicket(
            version: ticket.version,
            workspaceID: ticket.workspaceID,
            terminalID: ticket.terminalID,
            macDeviceID: ticket.macDeviceID,
            macDisplayName: ticket.macDisplayName,
            macUserEmail: nil,
            macUserID: ticket.macUserID,
            macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
            macAppVersion: ticket.macAppVersion,
            macAppBuild: ticket.macAppBuild,
            routes: tailscaleRoutes,
            // Fork (cmux Mochi): carry the real expiry and the attach token.
            // Upstream pins a far-future expiry and nils the token because there
            // the token authorizes nothing (Stack auth is the sole gate). This
            // fork's host authorizes on the ticket alone, so a code without the
            // token leaves a signed-out phone with nothing to present — it dials
            // the route and hangs. Both fields are standard on the full-key v1
            // model, so older clients decode them without trouble.
            expiresAt: ticket.expiresAt ?? Self.compatibilityExpiry,
            authToken: ticket.authToken
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = base64URLEncode(try encoder.encode(legacyTicket))
        return URL(
            string: "\(CmxPairingURLScheme.current)://attach?v=\(legacyTicket.version)&payload=\(payload)"
        )
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
