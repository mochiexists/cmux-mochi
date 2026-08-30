import CMUXMobileCore
import Foundation
import Observation

/// Drives the account-free iPhone pairing window. It turns on the DeviceLink
/// host, requires a non-loopback Tailscale route, and mints the single QR code
/// used to enroll the phone. The displayed code is regenerated only when the
/// user requests a refresh.
@MainActor
@Observable
final class MobilePairingModel {
    /// The pairing window's render state.
    enum State: Equatable {
        /// Resolving listener state before anything is shown.
        case loading
        /// Bringing the listener up and minting the first ticket.
        case preparing
        /// A ticket is ready to display.
        case ready(Ready)
        /// A phone has attached to the listener; show a paired/success state
        /// instead of the QR + spinner.
        case connected(Ready)
        /// No non-loopback Tailscale route is available yet.
        case needsReachableTransport
        /// The listener could not be started or no ticket could be minted.
        case failed(String)
    }

    /// A minted ticket ready for display.
    struct Ready: Equatable {
        /// The DeviceLink URL encoded into the QR code.
        let attachURL: String
        /// Reachable Tailscale `host:port` routes represented by the code.
        let tailscaleLines: [String]

        /// Whether at least one Tailscale route resolved.
        var reachableViaTailscale: Bool { !tailscaleLines.isEmpty }
    }

    struct PairingRoutePlan: Equatable, Sendable {
        /// The Tailscale endpoints eligible for the DeviceLink QR.
        let tailscaleLines: [String]

        static func make(routes: [CmxAttachRoute]) -> PairingRoutePlan? {
            let tailscaleLines = routes.compactMap(
                MobilePairingModel.phoneReachableTailscaleLine
            )
            guard !tailscaleLines.isEmpty else { return nil }
            return PairingRoutePlan(tailscaleLines: tailscaleLines)
        }
    }

    /// The current render state, observed by ``MobilePairingView``.
    private(set) var state: State = .loading

    private let host: MobileHostService
    private let ticketTTL: TimeInterval
    /// Observes host status while a code is shown and tracks new connections.
    /// Cancelled on each refresh.
    private var connectionObservationTask: Task<Void, Never>?
    /// Bumped on each ``refresh()`` so a slower in-flight run (the UI fires
    /// refresh from several places) can't overwrite a newer result with a stale
    /// ticket. Each run captures its value and bails after an `await` if superseded.
    private var refreshGeneration = 0

    /// Creates a pairing model.
    ///
    /// - Parameters:
    ///   - host: The Mac-side pairing host service, or `nil` to use the shared
    ///     instance. (Resolved in the `@MainActor` init body rather than as a
    ///     default argument, since default args are evaluated nonisolated and
    ///     `MobileHostService.shared` is main-actor isolated.)
    ///   - ticketTTL: Lifetime of the minted attach token in seconds. Defaults
    ///     to 600. The DeviceLink URL carries a single-use enrollment ticket,
    ///     not a reusable bearer credential.
    init(host: MobileHostService? = nil, ticketTTL: TimeInterval = 600) {
        self.host = host ?? .shared
        self.ticketTTL = ticketTTL
    }

    /// Brings the listener up and mints a fresh DeviceLink pairing code. Safe to
    /// call repeatedly from the Refresh button.
    func refresh() async {
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .preparing
        enablePairingHost()
        let status = await host.ensureListeningAndReady()
        guard generation == refreshGeneration else { return }
        guard status.isRunning else {
            // Show localized copy, not the raw NWListener error string.
            state = .failed(
                String(
                    localized: "mobile.pairing.error.listenerOffline",
                    defaultValue: "Could not start the pairing listener on this Mac."
                )
            )
            return
        }
        guard let routePlan = PairingRoutePlan.make(routes: status.routes) else {
            state = .needsReachableTransport
            observeRouteAvailability()
            return
        }
        do {
            // The QR is a v3 DeviceLink pairing code
            // (Mac TLS fingerprint + single-use enrollment ticket), not a legacy
            // bearer attach URL. The listener is mutual-TLS only, so an
            // un-enrolled phone scanning an attach URL dials the routes and then
            // stalls in the handshake — the pairing code is the only payload a
            // first-time phone can actually redeem.
            let pairingURL = try await MobileHostDeviceLink.shared.makePairingURL(lifetime: ticketTTL)
            guard generation == refreshGeneration else { return }
            state = .ready(
                Ready(
                    attachURL: pairingURL.absoluteString,
                    tailscaleLines: routePlan.tailscaleLines
                )
            )
            observeConnections()
        } catch MobileHostDeviceLinkPairingError.noRoutes {
            state = .needsReachableTransport
            observeRouteAvailability()
        } catch {
            state = .failed(
                String(
                    localized: "mobile.pairing.error.noTicket",
                    defaultValue: "Could not generate a pairing code. Try again."
                )
            )
        }
    }

    /// Cancels the connection observation. Call when the window closes.
    ///
    /// There is deliberately no timer to cancel: the displayed code never
    /// expires and is never regenerated behind the user's back. If a
    /// endpoint or private-network address changes while the window sits open,
    /// the Refresh Code button re-mints on demand.
    func stopObserving() {
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
    }

    /// Watches the mobile host's connection status while a code is displayed and
    /// flips `.ready` (QR shown, waiting) to `.connected` once a phone has
    /// attached. Success stays latched until an explicit refresh or window close;
    /// enrollment briefly reconnects while it installs the durable device identity,
    /// and letting that transport churn restore the QR makes a successful scan look
    /// like it failed. Cancelled and superseded on each ``refresh()`` via the generation
    /// guard, and on ``stopObserving()``.
    private func observeConnections() {
        connectionObservationTask?.cancel()
        let generation = refreshGeneration
        // Connections already present when this code is displayed (another phone
        // is attached, or we are pairing an additional device). Only a NEW
        // connection above this baseline means "this freshly minted QR was
        // scanned"; without the baseline, opening the window while a phone is
        // already connected would falsely jump to "connected" before the new
        // ticket is ever used, which also makes pairing an additional device
        // impossible (the QR would hide immediately).
        let baseline = host.statusSnapshot().activeConnectionCount
        connectionObservationTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.host.statusUpdates() {
                if Task.isCancelled { return }
                guard generation == self.refreshGeneration else { return }
                self.state = Self.connectionTransition(
                    from: self.state,
                    activeConnectionCount: status.activeConnectionCount,
                    baselineConnectionCount: baseline
                )
            }
        }
    }

    /// Automatically replaces the temporary no-route state when a Tailscale
    /// route appears. This is event-driven by the host status cache.
    private func observeRouteAvailability() {
        connectionObservationTask?.cancel()
        let generation = refreshGeneration
        connectionObservationTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.host.statusUpdates() {
                guard !Task.isCancelled,
                      generation == self.refreshGeneration else { return }
                guard PairingRoutePlan.make(routes: status.routes) != nil else {
                    continue
                }
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
                return
            }
        }
    }

    /// Computes the next render state from a connection-count change, relative to
    /// the `baselineConnectionCount` captured when the code was displayed. A
    /// connection *above* the baseline (a phone that attached after the QR was
    /// shown) flips a displayed ticket from `.ready` to `.connected`. Once shown,
    /// success is monotonic for that ticket; only ``refresh()`` may display a QR
    /// again. All other states pass through unchanged. Pure, so the transition is
    /// unit tested without a live host.
    static func connectionTransition(
        from current: State,
        activeConnectionCount: Int,
        baselineConnectionCount: Int
    ) -> State {
        let connected = activeConnectionCount > baselineConnectionCount
        switch current {
        case let .ready(ready) where connected:
            return .connected(ready)
        default:
            return current
        }
    }

    private func enablePairingHost() {
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
    }

    /// Formats a phone-reachable Tailscale route for the DeviceLink status UI.
    /// Iroh and loopback endpoints are deliberately excluded.
    private nonisolated static func phoneReachableTailscaleLine(
        _ route: CmxAttachRoute
    ) -> String? {
        guard route.kind == .tailscale,
              !CmxLoopbackHost().matches(route),
              case let .hostPort(host, port) = route.endpoint
        else {
            return nil
        }
        return "\(host):\(port)"
    }
}
