internal import CMUXMobileCore
internal import DeviceLinkKit
internal import CmuxMobileDiagnostics
internal import OSLog
public import CmuxMobileShellModel
import Foundation
#if canImport(UIKit)
import UIKit
#endif

private let deviceLinkLog = Logger(subsystem: "com.cmux-mochi", category: "DeviceLink")

/// Writes a DeviceLink event to both logs.
///
/// `os_log` is readable on a simulator but not retrievable from a physical
/// device with the tooling here; the app's own file log is. Pairing failures
/// that are invisible on hardware are exactly the ones that cost the most
/// time, so every event goes to both.
// lint:allow free-function — file-scoped dual-sink adapter shared by the
// MobileShellComposite extension; it owns no state and is not package API.
func logDeviceLink(_ message: String) {
    deviceLinkLog.info("\(message)")
    MobileDebugLog.shared.append("devicelink · \(message)")
}

@MainActor
extension MobileShellComposite {
    /// Recognizes a DeviceLink (v3) pairing code.
    ///
    /// Returns `nil` for anything else, so the legacy path keeps handling the
    /// codes it already understands until Phase 4 removes them.
    public static func isDeviceLinkPairingURL(_ rawURL: String) -> Bool {
        deviceLinkPairingPayload(from: rawURL) != nil
    }

    static func deviceLinkPairingPayload(from rawURL: String) -> PairingPayload? {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              PairingPayloadCoder.isPairingURL(url)
        else {
            logDeviceLink("not a pairing URL")
            return nil
        }
        do {
            let payload = try PairingPayloadCoder.decode(url)
            logDeviceLink("decoded code, routes=\(payload.routes.count)")
            return payload
        } catch {
            logDeviceLink("decode failed \(String(describing: error))")
            return nil
        }
    }

    /// Pairs with a Mac by exchanging public keys.
    ///
    /// Fork (cmux Mochi): no credential is transferred in either direction. The
    /// phone creates a key for this Mac, pins the Mac's key from the code, and
    /// enrolls inside the resulting mutually authenticated channel. What
    /// survives the launch is a key pair in the keychain — which is why this
    /// pairing reconnects after a cold start where the old ticket could not.
    func connectDeviceLinkPairing(payload: PairingPayload) async -> MobilePairingURLConnectionResult {
        // A completed key exchange IS this device's credential, so the shell is
        // authenticated from here on. Without this the pairing succeeds but
        // never persists: scope resolution requires a signed-in shell, and a
        // pairing that is not stored cannot be reconnected to — which looked
        // like a reconnect bug rather than a persistence one.
        if !isSignedIn { signIn() }
        _ = beginPairingValidationAttempt()
        connectionAttemptGeneration = UUID()
        clearPairingError()

        logDeviceLink("enrolling against \(payload.routes.joined(separator: ","))")
        let enroller = MobileDeviceLinkEnroller(deviceLabel: Self.deviceLinkDeviceLabel)
        do {
            let outcome = try await enroller.enroll(payload: payload)
            logDeviceLink("enrolled ok via \(outcome.route)")
            // A pairing that enrolled but did not persist is the worst outcome
            // to report as success: the key exists, so the next launch believes
            // it is paired, finds no Mac to dial, and gives up silently. Say so
            // now, while the user is still holding the QR code.
            guard await recordDeviceLinkPairing(outcome: outcome, payload: payload) else {
                applyPairingValidationFailure(.pairingNotSaved)
                return .failed
            }
            // Enrollment runs on its own short-lived transport and closes it, so
            // a completed pairing leaves no channel to use. Dial through the
            // stored-Mac reconnect path rather than `connect(ticket:)`.
            // Reconnect is the path built to select the request-scoped
            // DeviceLink identity for a Mac this device has already stored.
            let didConnect = await reconnectActiveMacIfAvailable(
                stackUserID: identityProvider?.currentUserID
            )
            logDeviceLink("post-pairing dial connected=\(didConnect)")
            // The pairing itself succeeded and is durable either way. A dial
            // that did not land is a reachability problem for the ordinary
            // retry path to solve, not a reason to tell the user their code
            // was bad and send them back to the QR screen.
            return .connected
        } catch let error as MobileDeviceLinkEnrollmentError {
            logDeviceLink("enrollment failed \(String(describing: error))")
            applyDeviceLinkFailure(error)
            return .failed
        } catch {
            logDeviceLink("unexpected \(String(describing: error))")
            applyPairingValidationFailure(.invalidCode)
            return .failed
        }
    }

    /// Persists a completed pairing so the next launch can reconnect.
    ///
    /// Reuses the existing ticket-shaped persistence rather than adding a
    /// second write path: the pairing identity travels as the ticket's
    /// `macDeviceID`, which is exactly the key the reconnect loop looks up.
    private func recordDeviceLinkPairing(
        outcome: MobileDeviceLinkEnrollmentOutcome,
        payload: PairingPayload
    ) async -> Bool {
        let routes = Self.orderedDeviceLinkRoutes(
            payloadRoutes: payload.routes,
            successfulRoute: outcome.route
        )
        // Record which pairing belongs to this Mac while both halves are known.
        // Reconnect otherwise has to guess which key to offer, and with more
        // than one paired Mac it guesses wrong.
        MobileDeviceLinkClient.shared.rememberPairing(
            macDeviceID: outcome.macDeviceID,
            instanceTag: outcome.macInstanceTag,
            pairingID: outcome.pairingID
        )
        logDeviceLink("recording pairing mac=\(outcome.macDeviceID.prefix(12)) tag=\(outcome.macInstanceTag ?? "nil") routes=\(routes.count) store=\(pairedMacStore == nil ? "MISSING" : "present")")
        guard !routes.isEmpty,
              let ticket = try? CmxAttachTicket(
                  workspaceID: "",
                  terminalID: nil,
                  macDeviceID: outcome.macDeviceID,
                  macDisplayName: outcome.macDisplayName ?? payload.macLabel,
                  routes: routes,
                  expiresAt: nil
              )
        else {
            logDeviceLink("pairing NOT persisted: no dialable route or ticket could be built")
            return false
        }
        // Record the instance tag too: build-compatibility checks compare it,
        // and a pairing stored without one is treated as an older host.
        let persisted = await persistPairedMacFromTicket(
            ticket,
            instanceTagUpdate: .replace(outcome.macInstanceTag),
            displayNameOverride: outcome.macDisplayName ?? payload.macLabel
        )
        logDeviceLink("pairing persisted=\(persisted)")
        return persisted
    }

    /// Rebuilds one advertised DeviceLink route with its concrete transport
    /// kind so reconnect ordering can prefer LAN without losing fallback.
    nonisolated static func deviceLinkRoute(
        from description: String,
        priority: Int = 0
    ) -> CmxAttachRoute? {
        guard let (host, port) = MobileDeviceLinkEnroller.splitHostPort(description) else {
            return nil
        }
        // Label the route by what it actually is. A loopback address stored as
        // a tailscale route is contradictory, and route policy checks disagree
        // about such a row - which is how a simulator pairing ends up with a
        // stored route nothing will dial.
        let isLoopback = CmxLoopbackHost().matches(host)
        let kind: CmxAttachTransportKind
        if isLoopback {
            kind = .debugLoopback
        } else if CmxPrivateLANHost().matches(host) {
            kind = .localNetwork
        } else {
            kind = .tailscale
        }
        return try? CmxAttachRoute(
            id: "\(kind.rawValue)-\(priority)",
            kind: kind,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }

    /// Rebuilds payload routes in the reconnect contract order: loopback for a
    /// simulator, then authenticated LAN, then Tailscale fallback. The route
    /// that completed enrollment breaks ties within one transport kind, but a
    /// temporary cellular pairing must not pin Tailscale ahead of LAN forever.
    nonisolated static func orderedDeviceLinkRoutes(
        payloadRoutes: [String],
        successfulRoute: String
    ) -> [CmxAttachRoute] {
        let successfulFirst = [successfulRoute] + payloadRoutes.filter { $0 != successfulRoute }
        let unprioritized = successfulFirst.compactMap { deviceLinkRoute(from: $0) }
        let ordered = unprioritized.enumerated().sorted { left, right in
            let leftRank = deviceLinkRouteRank(left.element.kind)
            let rightRank = deviceLinkRouteRank(right.element.kind)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return left.offset < right.offset
        }
        return ordered.enumerated().compactMap { priority, item in
            guard case let .hostPort(host, port) = item.element.endpoint else {
                return nil
            }
            return try? CmxAttachRoute(
                id: "\(item.element.kind.rawValue)-\(priority)",
                kind: item.element.kind,
                endpoint: .hostPort(host: host, port: port),
                priority: priority
            )
        }
    }

    nonisolated static func deviceLinkRouteRank(_ kind: CmxAttachTransportKind) -> Int {
        switch kind {
        case .debugLoopback:
            return 0
        case .localNetwork:
            return 1
        case .tailscale:
            return 2
        case .iroh, .websocket:
            return 3
        }
    }

    /// Maps an enrollment failure onto the pairing UI.
    ///
    /// A pin mismatch is deliberately *not* treated as a bad code: the code was
    /// fine, but something other than the expected Mac answered on that
    /// address, and the user needs to know that rather than be told to rescan.
    private func applyDeviceLinkFailure(_ error: MobileDeviceLinkEnrollmentError) {
        switch error {
        case .serverPinMismatch:
            // The code was fine; something that is not the expected Mac
            // answered on that address. Saying "invalid code" would send the
            // user to rescan a code that is not the problem.
            applyPairingValidationFailure(.listenerNotRunning(host: nil, port: nil))
        case .unreachable, .noRoutes:
            applyPairingValidationFailure(.hostUnreachable(host: nil, port: nil))
        case .refused, .identityUnavailable, .malformedResponse, .notADeviceLinkPayload:
            applyPairingValidationFailure(.invalidCode)
        }
    }

    /// A human-recognizable name for this phone, shown on the Mac's device list
    /// and in its enrollment notification.
    static var deviceLinkDeviceLabel: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : name
        #else
        return "iOS device"
        #endif
    }
}

extension MobileShellComposite {
    /// Records that a pairing URL reached the composite at all, which is the
    /// first thing to check when scanning a code appears to do nothing.
    public nonisolated static func logPairingURLArrival(_ rawURL: String) {
        logDeviceLink("pairing URL arrived, host=\(URL(string: rawURL)?.host ?? "nil")")
    }
}

extension MobileShellComposite {
    /// Notes that a stored key pair is standing in for an account session.
    public nonisolated static func logDeviceLinkReconnectAdoption() {
        logDeviceLink("paired key present, adopting device authentication")
    }

    /// Records that unpairing actually destroyed the device credential.
    ///
    /// Deleting the row is visible in the UI; destroying the key is not, and
    /// the two used to disagree. Naming it here is how a re-pair that silently
    /// reused the old identity stays diagnosable.
    public nonisolated static func logDeviceLinkPairingForgotten(
        macDeviceID: String,
        pairingID: String
    ) {
        logDeviceLink("forgot pairing mac=\(macDeviceID.prefix(12)) pairing=\(pairingID.prefix(24))")
    }
}

extension MobileShellComposite {
    /// Reports every input to the stored-Mac reconnect decision.
    ///
    /// A reconnect that silently does not happen is indistinguishable from one
    /// that failed, and the difference is the whole feature.
    public nonisolated static func logReconnectGate(
        uiTestURL: Bool,
        authenticated: Bool,
        stackAuthenticated: Bool,
        hasPairedDevice: Bool,
        restoring: Bool,
        connected: Bool
    ) {
        logDeviceLink(
            "reconnect gate uiTestURL=\(uiTestURL) authenticated=\(authenticated) "
                + "stack=\(stackAuthenticated) pairedDevice=\(hasPairedDevice) "
                + "restoring=\(restoring) connected=\(connected)"
        )
    }
}

extension MobileShellComposite {
    /// Reports the scope a stored-Mac reconnect resolved to.
    ///
    /// An account-free pairing lives under a local scope, so "no scope" and
    /// "not signed in" are the two ways this silently does nothing.
    public nonisolated static func logStoredMacReconnectScope(
        isSignedIn: Bool,
        requestedUserID: String?,
        resolvedUserID: String?
    ) {
        logDeviceLink("reconnect scope signedIn=\(isSignedIn) requested=\(requestedUserID ?? "nil") resolved=\(resolvedUserID ?? "nil")")
    }
}

extension MobileShellComposite {
    /// Reports whether a stored Mac's routes were considered dialable.
    public nonisolated static func logStoredMacDialDecision(
        mac: String,
        routeKinds: [String],
        hasDeviceLinkCredential: Bool,
        canConnect: Bool
    ) {
        logDeviceLink("dial decision mac=\(mac.prefix(28)) routes=\(routeKinds.joined(separator: ",")) credential=\(hasDeviceLinkCredential) canConnect=\(canConnect)")
    }
}

extension MobileShellComposite {
    /// Marks the point where a stored-Mac dial actually begins.
    /// Reports the endpoints a dial will actually attempt, after filtering.
    public nonisolated static func logStoredMacDialCandidates(_ endpoints: [String]) {
        logDeviceLink("dial candidates: \(endpoints.isEmpty ? "(none)" : endpoints.joined(separator: " "))")
    }

    public nonisolated static func logStoredMacDialStarted(mac: String, endpoints: [String] = []) {
        // Name the endpoints. Every other line says *that* a dial happened;
        // none said where to, which made "three attempts, all timed out"
        // impossible to attribute between a wrong address and a refused one.
        let where_ = endpoints.isEmpty ? "" : " -> \(endpoints.joined(separator: " "))"
        logDeviceLink("dialing stored mac \(mac.prefix(28))\(where_)")
    }
}

extension MobileShellComposite {
    /// Records how a stored-Mac dial ended.
    ///
    /// Without this the reconnect simply moves to the next candidate, and a
    /// failure that takes milliseconds looks identical to one that timed out.
    public nonisolated static func logStoredMacDialFinished(outcome: String) {
        logDeviceLink("dial finished: \(outcome.prefix(90))")
    }
}
