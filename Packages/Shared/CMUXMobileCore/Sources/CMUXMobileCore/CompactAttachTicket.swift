import Foundation

/// Compact short-key DTO for ``CmxAttachTicket``; see
/// ``CmxAttachTicketCompactCoder`` for the grammar and key map.
///
/// `JSONDecoder` ignores unknown keys, so payloads from the first compact
/// grammar revision that still carry `e` (expiry) and `n` (display name)
/// decode here with both intentionally dropped: a pairing QR never expires,
/// and the Mac's name is read post-handshake from `mobile.host.status`.
/// New Iroh pairing payloads disclose only EndpointID identity. The explicit
/// compatibility mode temporarily retains released clients' legacy routes.
struct CompactAttachTicket: Codable {
    let v: Int
    let w: String?
    let t: String?
    let d: String
    let u: String?
    let pc: Int?
    let av: String?
    let ab: String?
    let r: [CompactAttachRoute]
    /// Fork (cmux Mochi): the attach token, and the moment it dies.
    ///
    /// Upstream strips both, because there the token "never authorizes anything
    /// on the host (Stack auth is the sole gate)" and a pairing QR never expires.
    /// This fork inverts that: the host authorizes on the ticket alone, so the QR
    /// must actually CARRY the credential or a signed-out phone has nothing to
    /// present — it dials the route and hangs.
    ///
    /// That makes the QR bearer-grade, which is why it is paired with a short TTL
    /// (`x`, enforced host-side on every request) and, in Release, a tailnet-only
    /// listener. Treat a photographed QR as a live credential until it expires.
    let k: String?
    let x: Date?

    init(
        _ ticket: CmxAttachTicket,
        routeDisclosureMode: CmxPairingRouteDisclosureMode
    ) throws {
        let disclosedRoutes = ticket.routes.disclosed(for: routeDisclosureMode)
        guard !disclosedRoutes.isEmpty else {
            throw CmxAttachTicketCompactCoderError.noRoutesForDisclosureMode(
                routeDisclosureMode
            )
        }
        v = ticket.version
        w = ticket.workspaceID.isEmpty ? nil : ticket.workspaceID
        t = ticket.terminalID.flatMap { $0.isEmpty ? nil : $0 }
        d = ticket.macDeviceID
        u = ticket.macUserID.flatMap { $0.isEmpty ? nil : $0 }
        pc = ticket.macPairingCompatibilityVersion
        av = ticket.macAppVersion.flatMap { $0.isEmpty ? nil : $0 }
        ab = ticket.macAppBuild.flatMap { $0.isEmpty ? nil : $0 }
        r = disclosedRoutes.compacted()
        k = ticket.authToken.flatMap { $0.isEmpty ? nil : $0 }
        x = ticket.expiresAt
    }

    func ticket() throws -> CmxAttachTicket {
        try CmxAttachTicket(
            version: v,
            workspaceID: w ?? "",
            terminalID: t,
            macDeviceID: d,
            macDisplayName: nil,
            macUserEmail: u?.contains("@") == true ? u : nil,
            macUserID: u?.contains("@") == false ? u : nil,
            macPairingCompatibilityVersion: pc ?? 0,
            macAppVersion: av,
            macAppBuild: ab,
            routes: try r.expanded(),
            expiresAt: x,
            authToken: k
        )
    }
}

private extension Array where Element == CmxAttachRoute {
    func disclosed(for mode: CmxPairingRouteDisclosureMode) -> Self {
        switch mode {
        case .irohIdentityOnly:
            return compactMap { route in
                guard route.kind == .iroh,
                      case let .peer(identity, _) = route.endpoint else {
                    return nil
                }
                return try? CmxAttachRoute(
                    id: route.id,
                    kind: route.kind,
                    endpoint: .peer(identity: identity, pathHints: []),
                    priority: route.priority
                )
            }
        case .legacyPrivateNetworkCompatibility:
            return self
        }
    }

    /// Encode routes, omitting each route id the decoder can resynthesize.
    func compacted() -> [CompactAttachRoute] {
        var kindCounts: [CmxAttachTransportKind: Int] = [:]
        return map { route in
            let occurrence = (kindCounts[route.kind] ?? 0) + 1
            kindCounts[route.kind] = occurrence
            let synthesized = occurrence == 1
                ? route.kind.rawValue
                : "\(route.kind.rawValue)_\(occurrence)"
            return CompactAttachRoute(route, omittingID: route.id == synthesized)
        }
    }
}

private extension Array where Element == CompactAttachRoute {
    /// Decode routes, resynthesizing each omitted route id.
    func expanded() throws -> [CmxAttachRoute] {
        var kindCounts: [CmxAttachTransportKind: Int] = [:]
        return try map { compactRoute in
            let kind = try compactRoute.kind()
            let occurrence = (kindCounts[kind] ?? 0) + 1
            kindCounts[kind] = occurrence
            let synthesized = occurrence == 1
                ? kind.rawValue
                : "\(kind.rawValue)_\(occurrence)"
            return try compactRoute.route(synthesizedID: synthesized)
        }
    }
}
