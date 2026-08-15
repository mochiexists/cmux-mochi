import CMUXMobileCore
import CmuxMobileTransport
import DeviceLinkKit
import Foundation
import Network

extension MobileHostService {
    /// Reads the peer's certificate fingerprint from a connection whose TLS
    /// handshake has completed.
    ///
    /// Fork (cmux Mochi): the listener's verify block decides *whether* to
    /// admit; this reports *who* was admitted. Taking the identity from the
    /// handshake rather than from a request field is what makes it unforgeable
    /// by the client.
    ///
    /// Call only after the transport is connected — before that, no peer
    /// certificate exists to read.
    nonisolated static func deviceLinkPeerFingerprint(
        of connection: NWConnection
    ) -> DeviceFingerprint? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
            as? NWProtocolTLS.Metadata
        else { return nil }
        return DeviceLinkTLS.peerFingerprint(from: metadata)
    }

    /// Handles `mobile.pairing.device.enroll`.
    ///
    /// Fork (cmux Mochi): the enrolling device's identity is taken from the TLS
    /// handshake that carried this request, so a caller cannot enroll a key it
    /// does not hold the private half of. The request body supplies only the
    /// ticket and a display label.
    nonisolated static func deviceLinkEnrollmentResult(
        for request: MobileHostRPCRequest,
        authorization: MobileHostConnectionAuthorizationContext
    ) async -> MobileHostRPCResult {
        let fingerprintHex: String
        switch authorization {
        case let .enrollmentCandidate(fingerprint):
            fingerprintHex = fingerprint
        case let .pairedDevice(fingerprint, _):
            // Idempotent: a retry after a lost response re-presents the same
            // key, which is already enrolled. Report success rather than an
            // error the client would have to special-case.
            fingerprintHex = fingerprint
        case .stackBearer, .irohAdmission:
            return .failure(MobileHostRPCError(
                code: "unauthorized",
                message: "Device enrollment requires a DeviceLink connection."
            ))
        }

        guard let fingerprint = DeviceFingerprint(hex: fingerprintHex) else {
            return .failure(MobileHostRPCError(
                code: "unauthorized",
                message: "Device enrollment requires a DeviceLink connection."
            ))
        }
        guard let ticket = (request.params["ticket"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !ticket.isEmpty
        else {
            return .failure(MobileHostRPCError(
                code: "invalid_request",
                message: "ticket is required"
            ))
        }
        let label = (request.params["device_label"] as? String) ?? "Unnamed device"

        do {
            let outcome = try await MobileHostDeviceLink.shared.enroll(
                ticketSecret: ticket,
                fingerprint: fingerprint,
                label: label
            )
            return .ok([
                "enrolled": true,
                "already_enrolled": outcome.wasAlreadyEnrolled,
                "device_label": outcome.device.label,
                "fingerprint": outcome.device.fingerprint.hex,
            ])
        } catch EnrollmentError.ticketUnusable {
            // One error for absent, spent, and expired: a caller probing for
            // ticket existence learns nothing it did not already know.
            return .failure(MobileHostRPCError(
                code: "forbidden",
                message: "This pairing code is no longer valid. Generate a new one."
            ))
        } catch EnrollmentError.deviceQuotaExceeded {
            return .failure(MobileHostRPCError(
                code: "forbidden",
                message: "This Mac has reached its paired-device limit."
            ))
        } catch EnrollmentError.throttled {
            return .failure(MobileHostRPCError(
                code: "rate_limited",
                message: "Try pairing again in a moment."
            ))
        } catch {
            return .failure(MobileHostRPCError(
                code: "internal_error",
                message: "Pairing could not be saved."
            ))
        }
    }
}

extension MobileHostService {
    /// Republish routes once Tailscale MagicDNS has resolved, so a paired phone
    /// can hold an address-independent route to this Mac.
    ///
    /// Lives here rather than in `MobileHostService.swift` to keep the fork's
    /// footprint inside upstream files to the two visibility relaxations this
    /// needs.
    func publishRoutesAwaitingMagicDNS() async {
        guard let port = listenerPort else { return }
        // Capture the generation, not just the port. The port is a fixed
        // service port, so a listener that tore down and rebound during
        // resolution has the *same* port -- comparing ports alone would accept
        // routes resolved against the previous listener (and the previous
        // network path) as if they described the current one.
        let generation = listenerGeneration
        let snapshot = await routeResolver.routesResolvingTailscaleDNS(port: port)
        guard listenerGeneration == generation, listenerPort == port else { return }
        MobileHostPublicStatusCache.update(routes: snapshot.routes)
        logDeviceLinkHost("routes (magicdns awaited) -> \(Self.routeSummary(snapshot.routes))")
    }

    /// One-line `kind:host:port` summary of advertised routes, for diagnostics.
    static func routeSummary(_ routes: [CmxAttachRoute]) -> String {
        guard !routes.isEmpty else { return "(none)" }
        return routes.map { route in
            switch route.endpoint {
            case let .hostPort(host, port):
                return "\(route.kind.rawValue):\(host):\(port)"
            case let .peer(identity, _):
                return "\(route.kind.rawValue):peer:\(identity.endpointID.prefix(12))"
            case let .url(url):
                return "\(route.kind.rawValue):\(url)"
            }
        }.joined(separator: " ")
    }
}

extension MobileHostService {
    /// Whether a method is the DeviceLink enrollment verb -- the only RPC an
    /// enrollment candidate is allowed to call before it is paired.
    nonisolated static func isDeviceLinkEnrollmentMethod(_ method: String) -> Bool {
        method == "mobile.pairing.device.enroll"
    }
}

extension MobileHostService {
    nonisolated static func isTailnetEndpoint(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _)? = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 4 else { return false }
            // 100.64.0.0/10
            return bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127
        case let .ipv6(address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return false }
            // fd7a:115c:a1e0::/48
            if bytes[0] == 0xfd, bytes[1] == 0x7a, bytes[2] == 0x11, bytes[3] == 0x5c,
               bytes[4] == 0xa1, bytes[5] == 0xe0 {
                return true
            }
            // IPv4-mapped tailnet address ::ffff:100.64.0.0/10
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff,
               bytes[12] == 100, bytes[13] >= 64, bytes[13] <= 127 {
                return true
            }
            return false
        case .name:
            // Names are not resolved here; refuse rather than guess.
            return false
        @unknown default:
            return false
        }
    }

    /// Whether this connection actually arrived over the tailnet.
    ///
    /// SECONDARY check only. The real boundary is now the listener itself, which
    /// release builds pin to the Tailscale interface (see
    /// ``makeListenerParameters`` and ``MobileHostTailnetInterface``), so an
    /// off-tailnet connection is never accepted in the first place.
    ///
    /// This remains as cheap defence in depth, but do not mistake it for the
    /// boundary: every check of the PEER's address is forgeable by a machine on
    /// the same segment, and `100.64.0.0/10` is RFC 6598 shared CGNAT space that
    /// carriers and hotel networks also hand out (Codex review, 2026-07-26). Only
    /// the interface a connection lands on is beyond the peer's influence.
    ///
    /// Both endpoints come from Network.framework, not from RPC input, so neither
    /// is attacker-supplied. Missing/unresolved endpoints fail closed.
    nonisolated static func isTailnetConnection(_ connection: NWConnection) -> Bool {
        // `currentPath` is nil until the connection is STARTED, and the transport
        // starts it after this runs — so requiring the path here rejected every
        // legitimate connection (Codex round 3). Use the peer endpoint, which is
        // populated at accept time, and additionally require the LOCAL endpoint to
        // be a tailnet address whenever the path happens to be available.
        if let path = connection.currentPath {
            guard isTailnetEndpoint(path.localEndpoint) else { return false }
            return isTailnetEndpoint(path.remoteEndpoint) || isTailnetEndpoint(connection.endpoint)
        }
        return isTailnetEndpoint(connection.endpoint)
    }

    /// Listener parameters carrying the fork's DeviceLink mutual-TLS options.
    ///
    /// Upstream binds its listener with `NWParameters(tls: nil, ...)`; the fork
    /// authenticates keys at the transport, so the TLS options come from the
    /// authorized-devices coordinator. Kept here so upstream's two listener
    /// construction sites differ by one call each.
    static func deviceLinkListenerParameters(tcp tcpOptions: NWProtocolTCP.Options) throws -> NWParameters {
        // The coordinator loads its table on first read, so a cold start cannot
        // answer "unknown device" from an empty in-memory table while the real
        // one sits on disk.
        let tlsOptions = try MobileHostDeviceLink.shared.listenerOptions()
        return NWParameters(tls: tlsOptions, tcp: tcpOptions)
    }

    /// Completes the DeviceLink handshake for an accepted connection and
    /// resolves which key arrived.
    ///
    /// Returns `nil` when the peer must be refused, having already closed the
    /// transport. Admission is *derived* from the completed handshake rather
    /// than assumed: the verify block has already refused any key that is
    /// neither authorized nor mid-enrollment, and reading the peer certificate
    /// afterwards says which key it was, so the session runs under the right
    /// context.
    nonisolated static func admitDeviceLinkConnection(
        _ connection: NWConnection
    ) async -> (transport: CmxNetworkByteTransport, authorization: MobileHostConnectionAuthorizationContext)? {
        #if !DEBUG
        // Tickets authorize on their own, so the tailnet is the outer security
        // boundary -- enforce it rather than merely advertising tailnet routes.
        // The listener binds all interfaces, so without this a LAN peer holding
        // a leaked bearer could drive terminal input from hotel wifi. DEBUG
        // keeps every interface so the Simulator and LAN dogfood still work.
        if !Self.isTailnetConnection(connection) {
            mobileHostLog.error("mobile host rejected non-tailnet connection in release build")
            connection.cancel()
            return nil
        }
        #endif

        let transport = CmxNetworkByteTransport(acceptedConnection: connection)
        do {
            // `connect()` is idempotent, so the session's own later call
            // resolves immediately.
            try await transport.connect()
        } catch {
            // Name the reason. "handshake failed" alone cannot distinguish a
            // client that offered the wrong key from one that never presented a
            // certificate, from a peer that hung up mid-flight -- and on the
            // phone every one of them looks like an unreachable Mac.
            logDeviceLinkHost("rejected connection: handshake failed -- \(String(describing: error))")
            await transport.close()
            return nil
        }
        guard let fingerprint = Self.deviceLinkPeerFingerprint(of: connection) else {
            logDeviceLinkHost("rejected connection: no usable peer certificate")
            await transport.close()
            return nil
        }
        let authorization = await MobileHostDeviceLink.shared
            .authorizationContext(forPeer: fingerprint)
        // Record the admission so `last_seen_at` reflects connections, not just
        // enrollments -- otherwise it cannot show whether a reconnect landed.
        await MobileHostDeviceLink.shared.noteAdmission(fingerprint)
        logDeviceLinkHost("admitted \(String(describing: authorization).prefix(60))")
        return (transport, authorization)
    }
}

