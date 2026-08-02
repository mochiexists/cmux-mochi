internal import CMUXMobileCore
internal import DeviceLinkKit
internal import OSLog
public import CmuxMobileShellModel
import Foundation
#if canImport(UIKit)
import UIKit
#endif

private let deviceLinkLog = Logger(subsystem: "com.cmux-mochi", category: "DeviceLink")

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
            deviceLinkLog.info("devicelink: not a pairing URL")
            return nil
        }
        do {
            let payload = try PairingPayloadCoder.decode(url)
            deviceLinkLog.info("devicelink: decoded code, routes=\(payload.routes.count, privacy: .public)")
            return payload
        } catch {
            deviceLinkLog.info("devicelink: decode failed \(String(describing: error), privacy: .public)")
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

        deviceLinkLog.info("devicelink: enrolling against \(payload.routes.joined(separator: ","), privacy: .public)")
        let enroller = MobileDeviceLinkEnroller(deviceLabel: Self.deviceLinkDeviceLabel)
        do {
            let outcome = try await enroller.enroll(payload: payload)
            deviceLinkLog.info("devicelink: enrolled ok via \(outcome.route, privacy: .public)")
            await recordDeviceLinkPairing(outcome: outcome, payload: payload)
            return .connected
        } catch let error as MobileDeviceLinkEnrollmentError {
            deviceLinkLog.error("devicelink: enrollment failed \(String(describing: error), privacy: .public)")
            applyDeviceLinkFailure(error)
            return .failed
        } catch {
            deviceLinkLog.error("devicelink: unexpected \(String(describing: error), privacy: .public)")
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
        guard let route = Self.deviceLinkRoute(from: outcome.route),
              let ticket = try? CmxAttachTicket(
                  workspaceID: "",
                  terminalID: nil,
                  macDeviceID: outcome.pairingID,
                  macDisplayName: payload.macLabel,
                  routes: [route],
                  expiresAt: nil
              )
        else { return }
        await persistPairedMacFromTicket(ticket, displayNameOverride: payload.macLabel)
    }

    /// Rebuilds the route that worked, so reconnection starts where pairing
    /// succeeded rather than re-discovering it.
    private static func deviceLinkRoute(from description: String) -> CmxAttachRoute? {
        guard let (host, port) = MobileDeviceLinkEnroller.splitHostPort(description) else {
            return nil
        }
        return try? CmxAttachRoute(
            id: CmxAttachTransportKind.tailscale.rawValue,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port),
            priority: 0
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
        deviceLinkLog.info("devicelink: pairing URL arrived, host=\(URL(string: rawURL)?.host ?? "nil", privacy: .public)")
    }
}
