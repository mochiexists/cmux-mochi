import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTransport
import Foundation

@MainActor
extension MobileShellComposite {
    nonisolated static func boundedPairingRequestTimeoutNanoseconds(
        runtime: any MobileSyncRuntime,
        attemptStartedAt: Date
    ) -> UInt64 {
        let requestTimeout = runtime.pairingRequestTimeoutNanoseconds
        let attemptTimeout = runtime.pairingAttemptTimeoutNanoseconds
        guard attemptTimeout > 0 else {
            return requestTimeout
        }

        let elapsedSeconds = max(0, runtime.now().timeIntervalSince(attemptStartedAt))
        let elapsedNanoseconds = UInt64((elapsedSeconds * 1_000_000_000).rounded(.up))
        guard elapsedNanoseconds < attemptTimeout else {
            return 0
        }
        return min(requestTimeout, attemptTimeout - elapsedNanoseconds)
    }

    func syntheticManualHostTicket(
        displayName: String,
        macDeviceID: String,
        route: CmxAttachRoute
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "manual-workspace",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: displayName,
            routes: [route],
            expiresAt: Date().addingTimeInterval(60 * 60)
        )
    }

    func manualHostTicket(
        name: String,
        host: String,
        port: Int,
        attemptStartedAt: Date?,
        pairedMacDeviceID: String? = nil
    ) async throws -> CmxAttachTicket {
        let directRoute = try Self.manualHostRoute(host: host, port: port)
        let displayName = name.isEmpty ? host : name
        // Fork (cmux Mochi): minting an attach ticket needs a Stack access
        // token, and it is fetched *before* the transport is built — so on an
        // account-free device this path throws before a socket is ever opened.
        // Only loopback reaches it (`routeAllowsStackAuth` admits nothing else),
        // which is why this was invisible on hardware and fatal on the
        // simulator: the loopback candidate was consumed without a single dial,
        // leaving only tailnet addresses the Mac cannot reach from itself.
        //
        // A DeviceLink dial needs no ticket. It authorizes with the device's own
        // key under `.transportAdmission`, so go straight to the synthetic
        // ticket the non-loopback routes already use.
        let hasDeviceLinkCredential = MobileDeviceLinkClient.shared.hasAnyPairedDevice()
        if MobileShellRouteAuthPolicy.routeAllowsStackAuth(directRoute), !hasDeviceLinkCredential {
            do {
                let ticket = try await requestManualAttachTicket(
                    route: directRoute,
                    displayName: displayName,
                    attemptStartedAt: attemptStartedAt
                )
                return ticket
            } catch {
                guard Self.shouldFallbackToSyntheticManualTicket(after: error) else {
                    throw error
                }
            }
            return try syntheticManualHostTicket(
                displayName: displayName,
                macDeviceID: syntheticTicketMacDeviceID(
                    pairedMacDeviceID: pairedMacDeviceID, host: host, port: port
                ),
                route: directRoute
            )
        }
        return try syntheticManualHostTicket(
            displayName: displayName,
            macDeviceID: syntheticTicketMacDeviceID(
                pairedMacDeviceID: pairedMacDeviceID, host: host, port: port
            ),
            route: directRoute
        )
    }

    static func shouldFallbackToSyntheticManualTicket(after error: any Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedCode,
           ["method_not_found", "not_found", "unknown_method", "unsupported_method"].contains(normalizedCode) {
            return true
        }
        return normalizedMessage.contains("unknown method")
            || normalizedMessage.contains("method not found")
            || normalizedMessage.contains("unsupported method")
            || normalizedMessage.contains("ticket unavailable")
            || normalizedMessage.contains("ticket not available")
    }

    func requestManualAttachTicket(
        route: CmxAttachRoute,
        displayName: String,
        attemptStartedAt: Date?
    ) async throws -> CmxAttachTicket {
        guard let runtime else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        let probeTicket = try syntheticManualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-ticket-request",
            route: route
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: probeTicket,
            allowsStackAuthFallback: true,
            connectAttemptRegistry: connectAttemptRegistry,
            stackTokenGate: stackTokenGate,
            stackTokenForceRefreshGate: stackTokenForceRefreshGate,
            transportConnectObserver: transportConnectDiagnosticObserver
        )
        let timeoutNanoseconds: UInt64
        if let attemptStartedAt {
            timeoutNanoseconds = Self.boundedPairingRequestTimeoutNanoseconds(
                runtime: runtime,
                attemptStartedAt: attemptStartedAt
            )
            guard timeoutNanoseconds > 0 else {
                throw MobileShellConnectionError.requestTimedOut
            }
        } else {
            timeoutNanoseconds = runtime.pairingRequestTimeoutNanoseconds
        }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.attach_ticket.create",
            params: [
                "ttl_seconds": 3600,
                "scope": "mac",
                "target": "ticket_only",
            ]
        )
        let resultData: Data
        do {
            resultData = try await client.sendRequest(request, timeoutNanoseconds: timeoutNanoseconds)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
        let response = try MobileManualAttachTicketCreateResponse.decode(resultData)
        return try response.ticket.constrainingRoutes(to: [route], fallbackDisplayName: displayName)
    }

    /// The device id a synthetic ticket should claim.
    ///
    /// Fork (cmux Mochi): a stored-Mac dial claims **nothing**, on purpose.
    ///
    /// `applyHostReportedIdentity` branches on this value. Empty means "adopt":
    /// rebuild the ticket from the Mac's reported id and call
    /// `adoptForegroundMacIdentity`, which re-keys the foreground workspace
    /// aggregate onto the real Mac so the Computers screen sees it as connected
    /// and secondary aggregation excludes it. Non-empty means "verify", and a
    /// mismatch is `device_id_mismatch` followed by a disconnect.
    ///
    /// The placeholder `manual-<host>:<port>` was neither empty nor real, so it
    /// took the verify branch and was rejected ~90 ms after mutual TLS and the
    /// build and instance-tag checks had all passed — the connect/disconnect
    /// loop that left the UI offline on a connected phone.
    ///
    /// Claiming the *real* id instead passes verification but skips adoption, so
    /// the aggregate is never re-keyed: both Macs collapse into one bucket,
    /// showing the same single workspace under either selection with terminals
    /// that never load. Empty is the value the adopt branch was written for.
    /// `pairedMacDeviceID` still reaches `connect(...)` for route and pin
    /// selection; only the ticket's *claim* is withheld.
    func syntheticTicketMacDeviceID(
        pairedMacDeviceID: String?,
        host: String,
        port: Int
    ) -> String {
        let paired = pairedMacDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paired, !paired.isEmpty { return paired }
        return "manual-\(host):\(port)"
    }

}
