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
        _ = beginPairingValidationAttempt()
        connectionAttemptGeneration = UUID()
        clearPairingError()
        clearPairingVersionWarning()

        logDeviceLink("enrolling against \(payload.routes.joined(separator: ","))")
        let enroller = MobileDeviceLinkEnroller(deviceLabel: Self.deviceLinkDeviceLabel)
        do {
            let outcome = try await enroller.enroll(payload: payload)
            logDeviceLink("enrolled ok via \(outcome.route)")
            await recordDeviceLinkPairing(outcome: outcome, payload: payload)
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
    ) async {
        // Prefer the route that actually completed the pairing handshake: it is
        // the one proven to reach this Mac from this device. A simulator can
        // only use loopback (it shares the Mac's network stack, which cannot
        // TCP-connect to the Mac's own tailnet address), while a phone reaches
        // the tailnet address — so neither ordering is right in general, but
        // "what just worked" always is.
        let orderedDescriptions = [outcome.route] + payload.routes.filter { $0 != outcome.route }
        let routes = orderedDescriptions.enumerated().compactMap { index, description in
            Self.deviceLinkRoute(from: description, priority: index)
        }
        guard !routes.isEmpty,
              let ticket = try? CmxAttachTicket(
                  workspaceID: "",
                  terminalID: nil,
                  macDeviceID: outcome.pairingID,
                  macDisplayName: payload.macLabel,
                  routes: routes,
                  expiresAt: nil
              )
        else { return }
        await persistPairedMacFromTicket(ticket, displayNameOverride: payload.macLabel)
    }

    /// Rebuilds the route that worked, so reconnection starts where pairing
    /// succeeded rather than re-discovering it.
    private static func deviceLinkRoute(from description: String, priority: Int = 0) -> CmxAttachRoute? {
        guard let (host, port) = MobileDeviceLinkEnroller.splitHostPort(description) else {
            return nil
        }
        // Label the route by what it actually is. A loopback address stored as
        // a tailscale route is contradictory, and route policy checks disagree
        // about such a row - which is how a simulator pairing ends up with a
        // stored route nothing will dial.
        let isLoopback = host == "127.0.0.1" || host == "::1" || host.lowercased() == "localhost"
        let kind: CmxAttachTransportKind = isLoopback ? .debugLoopback : .tailscale
        return try? CmxAttachRoute(
            id: "\(kind.rawValue)-\(priority)",
            kind: kind,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
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
        attachTicket: Bool,
        restoring: Bool,
        connected: Bool
    ) {
        deviceLinkLog.info(
            """
            devicelink: reconnect gate uiTestURL=\(uiTestURL)             authenticated=\(authenticated)             stack=\(stackAuthenticated)             pairedDevice=\(hasPairedDevice)             attachTicket=\(attachTicket)             restoring=\(restoring)             connected=\(connected)
            """
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
        deviceLinkLog.info(
            """
            devicelink: reconnect scope signedIn=\(isSignedIn)             requested=\(requestedUserID ?? "nil")             resolved=\(resolvedUserID ?? "nil")
            """
        )
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
        deviceLinkLog.info(
            """
            devicelink: dial decision mac=\(mac.prefix(28))             routes=\(routeKinds.joined(separator: ","))             credential=\(hasDeviceLinkCredential)             canConnect=\(canConnect)
            """
        )
    }
}

extension MobileShellComposite {
    /// Marks the point where a stored-Mac dial actually begins.
    public nonisolated static func logStoredMacDialStarted(mac: String) {
        logDeviceLink("dialing stored mac \(mac.prefix(28))")
    }
}
