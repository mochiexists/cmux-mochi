import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Observation

/// Drives the in-app iOS pairing window. Gates pairing on the Mac being signed
/// in (authorization is a Stack same-account check), then turns on the
/// pairing host, mints an identity-only Iroh attach ticket, and exposes an
/// optional Tailscale compatibility code for released iOS clients. The
/// displayed code never expires and is never regenerated on a timer; Refresh
/// Code re-mints on demand.
///
/// Reads auth state from the app's shared ``CmuxAuthRuntime/AuthCoordinator``
/// (via `AppDelegate`); the browser sign-in is fire-and-forget and completion
/// is observed by the view through the coordinator's `@Observable` state.
@MainActor
@Observable
final class MobilePairingModel {
    /// The pairing window's render state.
    enum State: Equatable {
        /// Resolving auth/listener state before anything is shown.
        case loading
        /// The Mac is not signed in; pairing can't be authorized yet.
        case signedOut
        /// Signed in; bringing the listener up and minting the first ticket.
        case preparing
        /// A ticket is ready to display.
        case ready(Ready)
        /// A phone has attached to the listener; show a paired/success state
        /// instead of the QR + spinner.
        case connected(Ready)
        /// An attached phone's connection just dropped. Hold the paired layout
        /// (with a reconnecting hint) instead of flashing the QR back for every
        /// blip on a lossy network; falls back to ``ready(_:)`` only when the
        /// grace period expires without the phone returning. Entered only from
        /// ``connected(_:)`` — a first attach that never stabilized still shows
        /// the QR.
        case reconnecting(Ready)
        /// Neither an authenticated Iroh identity nor a released-client
        /// Tailscale compatibility route is available yet.
        case needsReachableTransport
        /// The listener could not be started or no ticket could be minted.
        case failed(String)
    }

    /// A minted ticket ready for display.
    struct Ready: Equatable {
        enum PrimaryTransport: Equatable, Sendable {
            case iroh
            case tailscaleCompatibility
        }

        /// The `cmux-ios://attach?...` URL encoded into the QR code.
        let attachURL: String
        /// A released-client-compatible Tailscale QR. Present only when Iroh is
        /// the primary code and the Mac also has a non-loopback tailnet route.
        let legacyAttachURL: String?
        /// The transport represented by ``attachURL``.
        let primaryTransport: PrimaryTransport
        /// The Mac's display name, shown above the code.
        let macName: String
        /// Reachable Tailscale `host:port` compatibility routes. Empty when
        /// Iroh is the only available transport.
        let tailscaleLines: [String]
        /// The best route for manual phone entry, behind the "Copy IP" and
        /// "Copy Port" buttons. `nil` when no phone-dialable route exists.
        let manualEntry: CmxManualPairingEntry?

        /// Whether at least one Tailscale route resolved.
        var reachableViaTailscale: Bool { !tailscaleLines.isEmpty }
        /// Whether the default QR authenticates and connects through Iroh.
        var reachableViaIroh: Bool { primaryTransport == .iroh }
    }

    struct PairingRoutePlan: Equatable, Sendable {
        let primaryDisclosureMode: CmxPairingRouteDisclosureMode
        let primaryTransport: Ready.PrimaryTransport
        let offersLegacyCode: Bool

        static func make(routes: [CmxAttachRoute]) -> PairingRoutePlan? {
            let hasIroh = routes.contains { route in
                guard route.kind == .iroh,
                      case .peer = route.endpoint else { return false }
                return true
            }
            let hasLegacyTailscale = routes.contains(
                where: MobilePairingModel.isPhoneReachableLegacyRoute
            )
            if hasIroh {
                return PairingRoutePlan(
                    primaryDisclosureMode: .irohIdentityOnly,
                    primaryTransport: .iroh,
                    offersLegacyCode: hasLegacyTailscale
                )
            }
            if hasLegacyTailscale {
                return PairingRoutePlan(
                    primaryDisclosureMode: .legacyPrivateNetworkCompatibility,
                    primaryTransport: .tailscaleCompatibility,
                    offersLegacyCode: false
                )
            }
            return nil
        }
    }

    /// The current render state, observed by ``MobilePairingView``.
    private(set) var state: State = .loading
    /// The signed-in account email, shown in the checklist. `nil` when signed out.
    private(set) var signedInEmail: String?

    private let host: MobileHostService
    private let ticketTTL: TimeInterval
    /// Observes host status while a code is shown. It upgrades an early
    /// compatibility code when Iroh publishes and tracks new connections.
    /// Cancelled on each refresh.
    private var connectionObservationTask: Task<Void, Never>?
    /// Bumped on each ``refresh()`` so a slower in-flight run (the UI fires
    /// refresh from several places) can't overwrite a newer result with a stale
    /// ticket. Each run captures its value and bails after an `await` if superseded.
    private var refreshGeneration = 0
    /// How long a dropped connection may stay away before ``State/reconnecting(_:)``
    /// gives up and the QR returns. Injectable so expiry is testable without
    /// waiting out the real grace period.
    private let reconnectGrace: Duration
    /// Pending fallback for the current ``State/reconnecting(_:)`` stretch.
    /// Cancelled the moment the connection count moves the state anywhere else.
    private var reconnectGraceTask: Task<Void, Never>?

    /// Creates a pairing model.
    ///
    /// - Parameters:
    ///   - host: The Mac-side pairing host service, or `nil` to use the shared
    ///     instance. (Resolved in the `@MainActor` init body rather than as a
    ///     default argument, since default args are evaluated nonisolated and
    ///     `MobileHostService.shared` is main-actor isolated.)
    ///   - ticketTTL: Lifetime of the minted attach token in seconds. Defaults
    ///     to 600. Covers only the RPC/v1 fallback token the mint produces as a
    ///     side effect; displayed Iroh and compatibility QRs carry no token and
    ///     never expire.
    ///   - reconnectGrace: How long a dropped connection may stay away before
    ///     the reconnecting hold falls back to the QR. Defaults to 10 seconds.
    init(
        host: MobileHostService? = nil,
        ticketTTL: TimeInterval = 600,
        reconnectGrace: Duration = .seconds(10)
    ) {
        self.host = host ?? .shared
        self.ticketTTL = ticketTTL
        self.reconnectGrace = reconnectGrace
    }

    private var coordinator: AuthCoordinator? { AppDelegate.shared?.auth?.coordinator }

    /// Re-evaluates sign-in state and, when signed in, brings the listener up
    /// and mints a fresh attach ticket. Safe to call repeatedly (Refresh button,
    /// or the view re-running it when auth state settles).
    func refresh() async {
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .loading
        guard let coordinator else {
            state = .failed(
                String(
                    localized: "mobile.pairing.error.listenerOffline",
                    defaultValue: "Could not start the pairing listener on this Mac."
                )
            )
            return
        }
        await coordinator.awaitBootstrapped()
        guard generation == refreshGeneration else { return }
        // Fork (cmux Mochi): NO ACCOUNT REQUIRED to pair.
        //
        // Upstream stops here when signed out, because its host demands a Stack
        // access token bound to the signed-in user on every mobile request. This
        // fork's host authorizes on the attach ticket alone — minted locally by
        // whoever controls this Mac, short-lived, and (in Release) only usable over
        // the tailnet. So the rest of this flow (enable host, await listener, mint
        // ticket, render QR) works signed out, and the sign-in gate was the ONLY
        // thing standing between a signed-out operator and a working QR code.
        //
        // Signing in remains supported and unchanged — it just is not required.
        signedInEmail = coordinator.isAuthenticated ? coordinator.currentUser?.primaryEmail : nil
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
            // Fork (cmux Mochi): DeviceLink codes carry this Mac's public-key
            // fingerprint and a single-use enrollment ticket — never a bearer
            // token. A photographed code is therefore worth at most one visible,
            // revocable enrollment inside a ten-minute window, instead of
            // working credentials for the ticket's whole life.
            //
            // Iroh pairing keeps its own upstream path; only the
            // Tailscale/TCP code changes here.
            let deviceLinkURL = try? await MobileHostDeviceLink.shared.makePairingURL()
            let payload: [String: Any]
            if let deviceLinkURL {
                payload = ["attach_url": deviceLinkURL.absoluteString]
            } else {
                payload = try await host.createAttachTicket(
                    workspaceID: "",
                    terminalID: nil,
                    ttl: ticketTTL,
                    routeDisclosureMode: routePlan.primaryDisclosureMode
                )
            }
            guard generation == refreshGeneration else { return }
            guard let attachURL = payload["attach_url"] as? String, !attachURL.isEmpty else {
                state = .failed(
                    String(
                        localized: "mobile.pairing.error.noTicket",
                        defaultValue: "Could not generate a pairing code. Try again."
                    )
                )
                return
            }
            // Fork (cmux Mochi): the legacy compatibility code embeds a bearer
            // token in the QR. With DeviceLink there is nothing it can pair that
            // the primary code cannot, so it is no longer offered.
            let legacyAttachURL: String? = nil
            state = .ready(
                Ready(
                    attachURL: attachURL,
                    legacyAttachURL: legacyAttachURL,
                    primaryTransport: routePlan.primaryTransport,
                    macName: Self.macDisplayName,
                    tailscaleLines: Self.tailscaleLines(status.routes),
                    manualEntry: CmxManualPairingEntry.best(in: status.routes)
                )
            )
            observeConnections()
        } catch MobileAttachTicketStoreError.noRoutes,
                MobileAttachTicketStoreError.routeUnavailable,
                MobileAttachTicketStoreError.invalidAttachURL {
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

    /// Launches the Mac browser sign-in flow. Fire-and-forget; the view re-runs
    /// ``refresh()`` when the coordinator's auth state settles.
    func signIn() {
        state = .loading
        AppDelegate.shared?.auth?.browserSignIn.beginSignIn()
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
        reconnectGraceTask?.cancel()
        reconnectGraceTask = nil
    }

    /// Watches the mobile host's connection status while a code is displayed and
    /// flips between `.ready` (QR shown, waiting) and `.connected` (a phone has
    /// attached). Cancelled and superseded on each ``refresh()`` via the generation
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
                if Self.shouldUpgradePrimaryTransport(
                    from: self.state,
                    routes: status.routes
                ) {
                    Task { @MainActor [weak self] in
                        guard let self,
                              generation == self.refreshGeneration else { return }
                        await self.refresh()
                    }
                    return
                }
                self.applyConnectionCount(
                    status.activeConnectionCount,
                    baseline: baseline,
                    generation: generation
                )
            }
        }
    }

    /// Applies a connection-count change and manages the reconnect grace timer:
    /// entering ``State/reconnecting(_:)`` arms the fallback to the QR, leaving
    /// it (the phone came back, or a refresh replaced the ticket) disarms it.
    private func applyConnectionCount(_ count: Int, baseline: Int, generation: Int) {
        let next = Self.connectionTransition(
            from: state,
            activeConnectionCount: count,
            baselineConnectionCount: baseline
        )
        state = next
        if case .reconnecting = next {
            armReconnectGraceFallback(generation: generation)
        } else {
            reconnectGraceTask?.cancel()
            reconnectGraceTask = nil
        }
    }

    /// Starts (or restarts) the timer that returns a lingering
    /// ``State/reconnecting(_:)`` to ``State/ready(_:)`` so the QR comes back
    /// after a real disconnect. A reattach cancels it via
    /// ``applyConnectionCount(_:baseline:generation:)``; a refresh supersedes it
    /// through the generation guard.
    private func armReconnectGraceFallback(generation: Int) {
        reconnectGraceTask?.cancel()
        reconnectGraceTask = Task { [weak self, reconnectGrace] in
            try? await Task.sleep(for: reconnectGrace)
            guard !Task.isCancelled,
                  let self,
                  generation == self.refreshGeneration,
                  let expired = Self.reconnectGraceExpiryState(from: self.state) else { return }
            self.state = expired
        }
    }

    /// The state to settle into when the reconnect grace period runs out: the
    /// QR returns. `nil` when the model has since moved on (reattached,
    /// refreshed, or torn down), meaning expiry must change nothing. Pure, so
    /// expiry is unit tested without a timer.
    static func reconnectGraceExpiryState(from current: State) -> State? {
        guard case let .reconnecting(ready) = current else { return nil }
        return .ready(ready)
    }

    /// Returns whether a displayed legacy compatibility code should be
    /// replaced now that an authenticated Iroh identity is available.
    static func shouldUpgradePrimaryTransport(
        from current: State,
        routes: [CmxAttachRoute]
    ) -> Bool {
        let ready: Ready
        switch current {
        case let .ready(value), let .connected(value), let .reconnecting(value):
            ready = value
        default:
            return false
        }
        guard ready.primaryTransport == .tailscaleCompatibility else {
            return false
        }
        return PairingRoutePlan.make(routes: routes)?.primaryTransport == .iroh
    }

    /// Automatically replaces the temporary no-route state when asynchronous
    /// Iroh registration or a Tailscale route appears. This is event-driven by
    /// the host status cache, so opening the pairing window never races a fast
    /// legacy listener against the usually-slightly-slower broker registration.
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
    /// shown) flips a displayed ticket from `.ready` to `.connected`; dropping
    /// back to the baseline enters `.reconnecting`, which holds the paired
    /// layout while the grace timer runs instead of flashing the QR back on
    /// every blip of a lossy network. A reattach during the hold returns to
    /// `.connected`; only grace expiry (see ``reconnectGraceExpiryState(from:)``)
    /// brings the QR back. All other states pass through unchanged. Pure, so
    /// the transition is unit tested without a live host.
    static func connectionTransition(
        from current: State,
        activeConnectionCount: Int,
        baselineConnectionCount: Int
    ) -> State {
        let connected = activeConnectionCount > baselineConnectionCount
        switch current {
        case let .ready(ready) where connected:
            return .connected(ready)
        case let .connected(ready) where !connected:
            return .reconnecting(ready)
        case let .reconnecting(ready) where connected:
            return .connected(ready)
        default:
            return current
        }
    }

    private func enablePairingHost() {
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
    }

    private static var macDisplayName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Whether `route` can serve released iOS clients: a Tailscale route that
    /// does not point back at this Mac. Iroh-capable clients use an identity-only
    /// route and never receive this private address in their default QR.
    private nonisolated static func isPhoneReachableLegacyRoute(
        _ route: CmxAttachRoute
    ) -> Bool {
        route.kind == .tailscale && !CmxLoopbackHost().matches(route)
    }

    private static func tailscaleLines(_ routes: [CmxAttachRoute]) -> [String] {
        routes.compactMap { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else {
                return nil
            }
            return "\(host):\(port)"
        }
    }
}
