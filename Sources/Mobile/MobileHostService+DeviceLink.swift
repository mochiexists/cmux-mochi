import CMUXMobileCore
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
