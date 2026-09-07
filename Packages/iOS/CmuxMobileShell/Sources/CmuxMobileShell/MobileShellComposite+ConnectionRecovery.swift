public import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import DeviceLinkKit
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
public import CmuxMobileTransport
public import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

enum StoredMacReconnectOutcome: Equatable, Sendable {
    case connected
    case failed(DiagnosticFailureKind)
    case superseded

    var didConnect: Bool {
        if case .connected = self { return true }
        return false
    }
}

@MainActor
extension MobileShellComposite {
    func startObservingNetworkPathChanges() {
        guard !networkPathObservationStarted else { return }
        networkPathObservationStarted = true
        let reachability = self.reachability
        networkPathObservationTask = Task { @MainActor [weak self] in
            // Each yield marks a meaningful path change (offline->online or a
            // primary-interface switch while online); recover the live
            // connection so a moving network repaints instead of going stale.
            for await _ in reachability.pathChanges() {
                guard let self, !Task.isCancelled else { return }
                let isOnline = await reachability.isOnline
                self.diagnosticLog?.record(DiagnosticEvent(
                    .reachabilityChanged,
                    a: isOnline ? 1 : 0
                ))
                self.recoverMobileConnection(trigger: .networkChange)
            }
        }
    }

    /// Foreground, network, presence, liveness, and stream-failure recovery all
    /// enter the same owner. Foreground starts with a positive-liveness probe;
    /// a failed probe promotes that exact attempt to one stored-Mac redial.
    func recoverForegroundConnectionIfNeeded(resyncAfterHealthy: Bool) {
        guard connectionState == .connected,
              let client = remoteClient,
              pairedMacStore != nil else { return }
        guard foregroundRefreshIsActive else {
            pendingInactiveRecoveryTrigger = .foreground
            return
        }
        beginConnectionRecovery(
            trigger: .foreground,
            expectedClient: client,
            probeCurrentConnection: true,
            resyncAfterHealthy: resyncAfterHealthy
        )
    }

    /// Single guarded recovery entry for every trigger (network change, manual
    /// Retry). When still connected, a network move usually only broke the event
    /// stream while input keeps flowing over the surviving connection, so a
    /// resync re-subscribes and requests a render-grid replay to repaint.
    /// Otherwise the connection dropped, so reconnect once; on failure the UI
    /// shows Retry and the next network change re-attempts automatically.
    func recoverMobileConnection(trigger: RecoveryTrigger) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        // A dial launched while the scene is inactive suspends with the
        // process; park the trigger and replay it once on foreground.
        guard foregroundRefreshIsActive else {
            pendingInactiveRecoveryTrigger = trigger
            return
        }
        if let accountID = reconnectBackoffScopeID() {
            switch trigger {
            case .manual, .networkChange, .foreground:
                clearTransientAutomaticReconnectBackoff(accountID: accountID)
            case .presencePush:
                guard !automaticIrohReconnectIsBlocked(accountID: accountID) else {
                    return
                }
            case .liveness, .eventStreamEnded, .subscriptionStartFailed,
                 .transportWriteTimedOut, .automaticBackoffExpired:
                break
            }
        }
        beginConnectionRecovery(
            trigger: trigger,
            expectedClient: remoteClient,
            probeCurrentConnection: connectionState == .connected && remoteClient != nil,
            resyncAfterHealthy: true
        )
        if multiMacAggregationEnabled, trigger.reschedulesSecondaryAggregation {
            scheduleSecondaryAggregation()
        }
    }

    /// A definitive event-stream failure bypasses same-client resubscription.
    /// Once the exact session is proven dead, rebuilding its listener only hides
    /// the failure behind the transport's reconnect behavior and leaves the
    /// shell owner stale. Instead, transition the one lifecycle owner to a fresh
    /// authenticated stored-Mac dial.
    func recoverDeadConnection(
        trigger: RecoveryTrigger,
        expectedClient: MobileCoreRPCClient
    ) {
        guard remoteClient === expectedClient, connectionState == .connected else { return }
        // The RPC session remains reusable after a transport EOF so request-
        // level recovery can replace a wedged transport. At this shell boundary,
        // however, the exact client has been classified as dead and is about to
        // lose ownership. Retire its synchronous factory gate before any queued
        // state-sync or notification request can redial it ahead of the owner-
        // managed replacement.
        if pairedMacStore != nil {
            expectedClient.retire()
        }
        guard foregroundRefreshIsActive else {
            pendingInactiveRecoveryTrigger = trigger
            return
        }

        // DeviceLink admission succeeded, but this authenticated channel still
        // ended. Short-lived successful handshakes are transport failures for
        // reconnect policy purposes; redialing immediately here created the
        // observed 5–20 second connect/stream-end storm. Park the cached shell
        // and let the shared 1/2/4/8/16 ladder own the next dial. A foreground
        // or manual trigger clears the cooldown through `recoverMobileConnection`.
        if let accountID = activeAccountFreeDeviceLinkScopeID() {
            if connectionRecoveryOwner.isRedialingOrValidating {
                let replacementIsInstalled = connectionRecoveryOwner.isValidatingReplacement
                    || connectionRecoveryOwner.activeAttempt?.sourceConnectionGeneration
                        != connectionGeneration
                guard replacementIsInstalled else { return }
                guard failConnectionRecoveryReplacement(
                    failure: .connectionClosed
                ) else { return }
            }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext(
                preservingOtherMacWorkspaceState: true,
                preservingSecondaryConnections: false
            )
            applyConnectionRecoveryOwnerState()
            recordDeviceLinkReconnectBackoff(
                accountID: accountID,
                failure: .connectionClosed
            )
            return
        }

        if connectionRecoveryOwner.isRedialingOrValidating {
            let replacementIsInstalled = connectionRecoveryOwner.isValidatingReplacement
                || connectionRecoveryOwner.activeAttempt?.sourceConnectionGeneration != connectionGeneration
            guard replacementIsInstalled else { return }
            guard failConnectionRecoveryReplacement(failure: .connectionClosed) else { return }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext(
                preservingOtherMacWorkspaceState: true,
                preservingSecondaryConnections: false
            )
            applyConnectionRecoveryOwnerState()
            return
        }

        let superseding = connectionRecoveryOwner.supersedeProbeWithRedial(
            trigger: trigger.description,
            sourceConnectionGeneration: connectionGeneration
        )
        startConnectionRecovery(
            trigger: trigger,
            expectedClient: expectedClient,
            probeCurrentConnection: false,
            resyncAfterHealthy: false,
            preclaimedAttempt: superseding
        )
    }

    private func activeAccountFreeDeviceLinkScopeID() -> String? {
        guard let accountID = reconnectBackoffScopeID(),
              MobileLocalPairingScope.isLocal(accountID),
              activeRoute?.kind != .iroh,
              let foregroundMacDeviceID,
              MobileDeviceLinkClient.shared.hasUsableCredential(
                  forMacDeviceID: foregroundMacDeviceID,
                  instanceTag: activeMacInstanceTag
              ) else { return nil }
        return accountID
    }

    /// Replays the most recent recovery trigger that was parked while the
    /// scene was inactive. Called from `resumeForegroundRefresh()` after the
    /// foreground recovery passes, so a replay coalesces into any attempt
    /// they already started instead of stacking a second dial.
    func recoverPendingInactiveRecoveryIfNeeded() {
        guard foregroundRefreshIsActive,
              let trigger = pendingInactiveRecoveryTrigger else { return }
        pendingInactiveRecoveryTrigger = nil
        recoverMobileConnection(trigger: trigger)
    }

    private func beginConnectionRecovery(
        trigger: RecoveryTrigger,
        expectedClient: MobileCoreRPCClient?,
        probeCurrentConnection: Bool,
        resyncAfterHealthy: Bool
    ) {
        startConnectionRecovery(
            trigger: trigger,
            expectedClient: expectedClient,
            probeCurrentConnection: probeCurrentConnection,
            resyncAfterHealthy: resyncAfterHealthy,
            preclaimedAttempt: nil
        )
    }

    private func startConnectionRecovery(
        trigger: RecoveryTrigger,
        expectedClient: MobileCoreRPCClient?,
        probeCurrentConnection: Bool,
        resyncAfterHealthy: Bool,
        preclaimedAttempt: MobileConnectionRecoveryOwner.Attempt?
    ) {
        // Fork (cmux Mochi): recovery tears the connection down and redials, so
        // a trigger that fires on every successful connect is an infinite loop
        // the user experiences as "it never connects". The existing log goes to
        // anchormux, which the on-device debug log does not carry — so the loop
        // was visible on the phone and its cause was not.
        //
        // Logged HERE, not in `beginConnectionRecovery`: a reproduction on the
        // iPhone 16 showed the loop running with neither that function's log nor
        // the launch path's `reconnect gate` line, which means it arrives
        // through a caller that reaches this one directly.
        MobileDeviceLinkDiagnostics.log(
            "connection recovery: trigger=\(trigger.description) probe=\(probeCurrentConnection) "
                + "preclaimed=\(preclaimedAttempt != nil) state=\(connectionState)"
        )
        guard pairedMacStore != nil else {
            guard connectionState == .connected else { return }
            // Preview/legacy clients can have a live RPC shell without durable
            // pairing state. Liveness and network-path changes can rebuild that
            // listener on the existing client, but a definitively ended stream
            // cannot safely invent a redial route and must remain unavailable.
            switch trigger {
            case .liveness, .networkChange:
                markMacConnectionReconnecting()
                resyncTerminalOutput(reason: trigger.description, restartEventStream: true)
            case .manual, .presencePush, .foreground, .eventStreamEnded,
                 .subscriptionStartFailed, .transportWriteTimedOut, .automaticBackoffExpired:
                markMacConnectionUnavailableIfNoStore()
            }
            return
        }
        let attempt = preclaimedAttempt ?? connectionRecoveryOwner.begin(
            trigger: trigger.description,
            sourceConnectionGeneration: connectionGeneration,
            probing: probeCurrentConnection
        )
        guard let attempt else { return }
        diagnosticLog?.record(DiagnosticEvent(
            .recoveryStarted,
            a: activeRoute.map { DiagnosticTransportKind($0.kind).rawValue }
                ?? DiagnosticTransportKind.unknown.rawValue,
            b: trigger.diagnosticCode
        ))
        applyConnectionRecoveryOwnerState()
        let stackUserID = lastReconnectStackUserID ?? identityProvider?.currentUserID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskCancellationHandler {
                defer { self.connectionRecoveryOwner.clearTask(for: attempt) }
                guard self.connectionRecoveryOwner.isCurrent(attempt) else { return }

                if probeCurrentConnection, let expectedClient {
                    let epochAtProbeStart = self.foregroundResumeEpoch
                    let healthy = await self.reloadWorkspaceListFromMac(
                        timeoutNanoseconds: self.runtime?.livenessProbeTimeoutNanoseconds
                    )
                    guard !Task.isCancelled,
                          self.connectionRecoveryOwner.isCurrent(attempt),
                          self.remoteClient === expectedClient,
                          self.connectionGeneration == attempt.sourceConnectionGeneration else {
                        return
                    }
                    if healthy {
                        guard self.completeConnectionRecovery(attempt) else { return }
                        self.markMacConnectionHealthy()
                        if resyncAfterHealthy {
                            self.resyncTerminalOutput(
                                reason: "connectionRecovery.\(trigger)",
                                restartEventStream: true
                            )
                        }
                        self.applyConnectionRecoveryOwnerState()
                        return
                    }
                    if self.lastBackgroundedAt != nil
                        || self.foregroundResumeEpoch != epochAtProbeStart {
                        // The probe spanned a background window: its wall-clock
                        // deadline burned while the process was suspended, so
                        // the timeout is not evidence of a dead connection.
                        // Abandon this attempt without teardown; if we are
                        // foreground again, probe once more with a fresh deadline.
                        MobileDebugLog.anchormux(
                            "connection.recovery probe abandoned: spanned background window"
                        )
                        _ = self.connectionRecoveryOwner.complete(attempt)
                        self.applyConnectionRecoveryOwnerState()
                        if self.lastBackgroundedAt == nil {
                            self.recoverForegroundConnectionIfNeeded(
                                resyncAfterHealthy: resyncAfterHealthy
                            )
                        }
                        return
                    }
                }

                guard !Task.isCancelled,
                      self.connectionRecoveryOwner.transitionToRedialing(attempt) else { return }
                if let expectedClient {
                    guard self.remoteClient === expectedClient else { return }
                    // Detach the stale shell synchronously on the main actor
                    // before awaiting its transport teardown. This cancels every
                    // tracked producer and makes untracked producers fail their
                    // identity guard, so they cannot reopen the old endpoint
                    // while the fresh stored-Mac dial starts.
                    self.connectionState = .disconnected
                    self.macConnectionStatus = .unavailable
                    self.clearRemoteConnectionContext(
                        preservingOtherMacWorkspaceState: true,
                        preservingSecondaryConnections: false
                    )
                    self.applyConnectionRecoveryOwnerState()
                    await expectedClient.disconnect()
                    guard !Task.isCancelled,
                          self.connectionRecoveryOwner.isCurrent(attempt) else { return }
                }
                if self.connectionState == .connected {
                    self.connectionState = .disconnected
                    self.macConnectionStatus = .unavailable
                    self.clearRemoteConnectionContext(
                        preservingOtherMacWorkspaceState: true,
                        preservingSecondaryConnections: false
                    )
                }
                self.applyConnectionRecoveryOwnerState()

                // Recovery uses authenticated local Iroh state first. A stuck
                // account-backup fetch must not block a known EndpointID from
                // dialing; normal launch reconnect still refreshes first. The
                // shared reconnect entry owns the hard deadline after claiming
                // its generation synchronously, so every lifecycle caller gets
                // the same wedge protection without a second race here.
                let reconnectOutcome = await self.reconnectActiveMacOutcome(
                    stackUserID: stackUserID,
                    refreshBackupBeforeDial: false
                )
                guard !Task.isCancelled,
                      self.connectionRecoveryOwner.isCurrent(attempt) else { return }
                guard self.settleConnectionRecovery(
                    attempt,
                    outcome: reconnectOutcome,
                    connectionGeneration: self.connectionGeneration
                ) else { return }
                self.applyConnectionRecoveryOwnerState()
            } onCancel: {
                MobileDebugLog.anchormux(
                    "connection.recovery cancelled trigger=\(trigger.description) attempt=\(attempt.id.uuidString)"
                )
            }
        }
        connectionRecoveryOwner.install(task, for: attempt)
    }

    @discardableResult
    func completeConnectionRecovery(
        _ attempt: MobileConnectionRecoveryOwner.Attempt
    ) -> Bool {
        guard connectionRecoveryOwner.complete(attempt) else { return false }
        recordConnectionRecoverySucceeded()
        return true
    }

    @discardableResult
    func settleSuccessfulConnectionRecovery(
        _ attempt: MobileConnectionRecoveryOwner.Attempt,
        connectionGeneration: UUID
    ) -> Bool {
        if lastSuccessfulTerminalSubscriptionGeneration == connectionGeneration {
            return completeConnectionRecovery(attempt)
        }
        return connectionRecoveryOwner.transitionToValidation(
            attempt,
            connectionGeneration: connectionGeneration
        )
    }

    @discardableResult
    func settleConnectionRecovery(
        _ attempt: MobileConnectionRecoveryOwner.Attempt,
        outcome: StoredMacReconnectOutcome,
        connectionGeneration: UUID
    ) -> Bool {
        switch outcome {
        case .connected:
            return settleSuccessfulConnectionRecovery(
                attempt,
                connectionGeneration: connectionGeneration
            )
        case .failed(let failure):
            return failConnectionRecovery(attempt, failure: failure)
        case .superseded:
            return failConnectionRecovery(attempt, failure: .superseded)
        }
    }

    @discardableResult
    func failConnectionRecovery(
        _ attempt: MobileConnectionRecoveryOwner.Attempt,
        failure: DiagnosticFailureKind
    ) -> Bool {
        guard connectionRecoveryOwner.fail(attempt) else { return false }
        recordConnectionRecoveryFailed(failure)
        return true
    }

    @discardableResult
    func failConnectionRecoveryReplacement(
        failure: DiagnosticFailureKind
    ) -> Bool {
        guard connectionRecoveryOwner.failReplacement() != nil else { return false }
        recordConnectionRecoveryFailed(failure)
        return true
    }

    private func recordConnectionRecoverySucceeded() {
        diagnosticLog?.record(DiagnosticEvent(
            .recoverySucceeded,
            a: activeRoute.map { DiagnosticTransportKind($0.kind).rawValue }
                ?? DiagnosticTransportKind.unknown.rawValue
        ))
    }

    private func recordConnectionRecoveryFailed(_ failure: DiagnosticFailureKind) {
        diagnosticLog?.record(DiagnosticEvent(
            .recoveryFailed,
            a: activeRoute.map { DiagnosticTransportKind($0.kind).rawValue }
                ?? DiagnosticTransportKind.unknown.rawValue,
            b: failure.rawValue
        ))
    }

    func recordSuccessfulTerminalSubscription() {
        lastSuccessfulTerminalSubscriptionGeneration = connectionGeneration
        if connectionRecoveryOwner.completeValidation(connectionGeneration: connectionGeneration) {
            recordConnectionRecoverySucceeded()
            applyConnectionRecoveryOwnerState()
        }
    }

    func applyConnectionRecoveryOwnerState() {
        switch connectionRecoveryOwner.phase {
        case .idle:
            isRecoveringConnection = false
            connectionRecoveryFailed = false
        case .probing:
            // A probe is a background health check on a connection still
            // believed healthy: the terminal stays interactive and the visible
            // status untouched. Only an actual redial may surface reconnecting
            // UI (the picker status line and terminal status pill).
            isRecoveringConnection = false
            connectionRecoveryFailed = false
        case .redialing, .validatingReplacement:
            isRecoveringConnection = true
            connectionRecoveryFailed = false
            if connectionState == .connected { markMacConnectionReconnecting() }
        case .failed:
            isRecoveringConnection = false
            connectionRecoveryFailed = true
        }
    }

    private func markMacConnectionUnavailableIfNoStore() {
        macConnectionStatus = .unavailable
        isRecoveringConnection = false
        connectionRecoveryFailed = true
    }

    static func storedMacTicket(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "stored-workspace",
            terminalID: nil,
            macDeviceID: pairedMacDeviceID,
            macDisplayName: name,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: routes
        )
    }

    /// Reconnects an already-paired Mac through its full route set.
    ///
    /// The synthetic ticket names the already-paired device and never creates a
    /// new pairing. Network routes are admitted only by the exact DeviceLink
    /// identity for that device and app instance.
    func connectStoredMacRoutes(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        let ticket: CmxAttachTicket
        do {
            ticket = try Self.storedMacTicket(
                name: name,
                routes: routes,
                pairedMacDeviceID: pairedMacDeviceID
            )
            _ = try await connect(
                ticket: ticket,
                pairedMacDeviceID: pairedMacDeviceID,
                ifStillCurrent: ifStillCurrent
            )
        } catch {
            guard ifStillCurrent?() ?? true else { return }
            mobileShellLog.warning(
                "stored route reconnect failed mac=\(pairedMacDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            if disconnectForAuthorizationFailureIfNeeded(error) { return }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        }
    }

    /// Connects an existing pairing through its strongest supported transport.
    /// A supported Iroh identity pins the attempt to Iroh. Network routes use
    /// the exact DeviceLink credential for the stored Mac and app instance.
    @discardableResult
    func connectStoredMac(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        (await connectStoredMacOutcome(
            name: name,
            routes: routes,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTag: nil,
            ifStillCurrent: ifStillCurrent
        )).didConnect
    }

    /// Reconnects a stored Mac through its Iroh-pinned route set while also
    /// enforcing the authenticated app-instance authority captured by storage.
    @discardableResult
    func connectStoredMac(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        instanceTag: String?,
        automaticReconnectAccountID: String? = nil,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        (await connectStoredMacOutcome(
            name: name,
            routes: routes,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTag: instanceTag,
            automaticReconnectAccountID: automaticReconnectAccountID,
            ifStillCurrent: ifStillCurrent
        )).didConnect
    }

    func connectStoredMacOutcome(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        instanceTag: String?,
        automaticReconnectAccountID: String? = nil,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> StoredMacReconnectOutcome {
        await connectStoredMacOutcome(
            name: name,
            routes: routes,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTagExpectation: macInstanceTagAuthority.expectation(
                storedInstanceTag: instanceTag
            ),
            automaticReconnectAccountID: automaticReconnectAccountID,
            ifStillCurrent: ifStillCurrent
        )
    }

    /// Connects through a stored route set while enforcing the caller's exact
    /// authenticated instance-authority requirement.
    @discardableResult
    private func connectStoredMacOutcome(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        instanceTagExpectation: MobileMacInstanceTagExpectation,
        automaticReconnectAccountID: String? = nil,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> StoredMacReconnectOutcome {
        guard ifStillCurrent?() ?? true else { return .superseded }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let pinnedRoutes = Self.storedReconnectRoutes(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard !pinnedRoutes.isEmpty else {
            // Routes are filtered and reordered before a dial; a stored Mac
            // whose rows all get dropped here is indistinguishable from one
            // that was never saved, and on a physical device the surviving set
            // differs from the simulator's.
            logDeviceLink(
                "dial aborted: no dialable route "
                    + "stored=\(routes.map(\.kind.rawValue).joined(separator: ",")) "
                    + "supported=\(supportedKinds.map(\.rawValue).joined(separator: ","))"
            )
            return .failed(.unsupportedRoute)
        }

        var outcome: StoredMacReconnectOutcome = .failed(.unknown)

        // A Mac this device holds a DeviceLink key and pin for is dialed
        // directly with that exact identity over mutual TLS.
        let hasDeviceLinkCredential = MobileDeviceLinkClient.shared
            .hasUsableCredential(
                forMacDeviceID: pairedMacDeviceID,
                instanceTag: instanceTagExpectation.deviceLinkInstanceTag
            )
        MobileShellComposite.logStoredMacDialDecision(
            mac: pairedMacDeviceID,
            routeKinds: pinnedRoutes.map { route in
                guard case let .hostPort(host, port) = route.endpoint else {
                    return route.kind.rawValue
                }
                return "\(route.kind.rawValue)@\(host):\(port)"
            },
            hasDeviceLinkCredential: hasDeviceLinkCredential,
            canConnect: true
        )
        do {
            let ticket = try Self.storedMacTicket(
                name: name,
                routes: pinnedRoutes,
                pairedMacDeviceID: pairedMacDeviceID
            )
            // `connect(ticket:)` installs this exact dial target only after it
            // retires a superseded attempt and confirms this one is current.
            // The injected transport factory owns admission; the shell never
            // substitutes a bearer or reaches into a concrete credential store.
            MobileShellComposite.logStoredMacDialStarted(
                mac: pairedMacDeviceID,
                endpoints: pinnedRoutes.compactMap { route in
                    guard case let .hostPort(host, port) = route.endpoint else { return nil }
                    return "\(host):\(port)"
                }
            )
            let noThrowFailure = try await connect(
                ticket: ticket,
                pairedMacDeviceID: pairedMacDeviceID,
                instanceTagExpectation: instanceTagExpectation,
                ifStillCurrent: ifStillCurrent
            )
            guard ifStillCurrent?() ?? true else { return .superseded }
            MobileShellComposite.logStoredMacDialFinished(
                outcome: "direct failure=\(noThrowFailure.map { String(describing: $0) } ?? "none") state=\(connectionState)"
            )
            if noThrowFailure == .noSupportedRoute {
                outcome = .failed(.unsupportedRoute)
            }
        } catch {
            guard ifStillCurrent?() ?? true else { return .superseded }
            MobileShellComposite.logStoredMacDialFinished(
                outcome: "direct threw \(String(describing: error))"
            )
            outcome = .failed(Self.diagnosticFailureKind(for: error))
            if let automaticReconnectAccountID {
                recordAutomaticReconnectBackoff(
                    error: error,
                    accountID: automaticReconnectAccountID
                )
            }
            // `connect(ticket:)` stages a different Mac without disturbing the
            // live foreground. A rejected candidate must not convert that
            // healthy foreground into an offline interval while route refresh
            // tries the next authenticated transport.
            if hasActiveMacConnection {
                // The target-specific failure is returned in `outcome`; keep
                // the foreground's connection state and ownership untouched.
            } else if !disconnectForAuthorizationFailureIfNeeded(error) {
                connectionState = .disconnected
                macConnectionStatus = .unavailable
                // A failed replacement is an offline interval, not a new
                // shell. Keep the last authenticated workspace snapshot so
                // a transient DERP/TCP drop does not flash the QR screen or
                // erase useful scrollback while policy schedules redial.
                clearRemoteConnectionContext(
                    preservingOtherMacWorkspaceState: true,
                    preservingSecondaryConnections: false
                )
            }
        }

        let connected = (ifStillCurrent?() ?? true)
            && connectionState == .connected
            && remoteClient != nil
            && foregroundMacDeviceID == pairedMacDeviceID
        if connected, let automaticReconnectAccountID {
            clearAutomaticReconnectBackoff(accountID: automaticReconnectAccountID)
        }
        return connected ? .connected : outcome
    }

    func automaticIrohReconnectIsBlocked(accountID: String) -> Bool {
        automaticReconnectBackoffOwner.isBlocked(
            accountID: accountID,
            now: runtime?.now() ?? Date()
        )
    }

    func recordAutomaticReconnectBackoff(error: any Error, accountID: String) {
        guard let retryAfterError = error as? any CmxRetryAfterProviding,
              let retryAfterSeconds = retryAfterError.retryAfterSeconds else { return }
        let now = runtime?.now() ?? Date()
        let retryAt = automaticReconnectBackoffOwner.record(
            accountID: accountID,
            retryAfterSeconds: retryAfterSeconds,
            now: now
        )
        scheduleAutomaticReconnectRetry(accountID: accountID, retryAt: retryAt, now: now)
    }

    func recordTransientAutomaticReconnectBackoff(accountID: String) {
        let now = runtime?.now() ?? Date()
        let retryAt = automaticReconnectBackoffOwner.recordTransientFailure(
            accountID: accountID,
            now: now
        )
        scheduleAutomaticReconnectRetry(accountID: accountID, retryAt: retryAt, now: now)
    }

    func recordDeviceLinkReconnectBackoff(
        accountID: String,
        failure: DiagnosticFailureKind
    ) {
        let outcome: ConnectionAttemptOutcome = switch failure {
        case .identityMismatch:
            .serverPinMismatch
        case .admissionDenied, .authorizationFailed, .credentialUnavailable:
            .rejectedByPeer
        default:
            .unreachable
        }
        guard case .retry = ReconnectPolicy.default.decision(
            after: outcome,
            attempt: automaticReconnectBackoffOwner.transientFailureCount + 1
        ) else {
            clearAutomaticReconnectBackoff(accountID: accountID)
            return
        }
        let now = runtime?.now() ?? Date()
        let retryAt = automaticReconnectBackoffOwner.recordDeviceLinkFailure(
            accountID: accountID,
            policy: .default,
            now: now
        )
        scheduleAutomaticReconnectRetry(accountID: accountID, retryAt: retryAt, now: now)
    }

    func recordDeviceLinkConnectionHealthy(accountID: String) {
        automaticReconnectBackoffOwner.recordDeviceLinkHealthy(
            accountID: accountID,
            now: runtime?.now() ?? Date()
        )
        automaticReconnectRetryTask?.cancel()
        automaticReconnectRetryTask = nil
        automaticReconnectRetryAccountID = nil
        automaticReconnectRetryAt = nil
    }

    func reconnectBackoffScopeID(explicitAccountID: String? = nil) -> String? {
        if let accountID = explicitAccountID ?? identityProvider?.currentUserID {
            return accountID
        }
        guard hasKnownPairedMac else { return nil }
        return MobileLocalPairingScope.identifier()
    }

    func reconnectScopeMatches(_ accountID: String) -> Bool {
        if MobileLocalPairingScope.isLocal(accountID) {
            return identityProvider?.currentUserID == nil && hasKnownPairedMac
        }
        return isSignedIn && identityProvider?.currentUserID == accountID
    }

    func clearTransientAutomaticReconnectBackoff(accountID: String) {
        automaticReconnectBackoffOwner.clearTransientCooldown(accountID: accountID)
        let now = runtime?.now() ?? Date()
        if let retryAt = automaticReconnectBackoffOwner.retryAt, retryAt > now {
            scheduleAutomaticReconnectRetry(accountID: accountID, retryAt: retryAt, now: now)
        } else {
            automaticReconnectRetryTask?.cancel()
            automaticReconnectRetryTask = nil
            automaticReconnectRetryAccountID = nil
            automaticReconnectRetryAt = nil
        }
    }

    func clearAutomaticReconnectBackoff(accountID: String? = nil) {
        automaticReconnectBackoffOwner.clear(accountID: accountID)
        guard accountID == nil || automaticReconnectBackoffOwner.accountID == nil else { return }
        automaticReconnectRetryTask?.cancel()
        automaticReconnectRetryTask = nil
        automaticReconnectRetryAccountID = nil
        automaticReconnectRetryAt = nil
    }

    private func scheduleAutomaticReconnectRetry(
        accountID: String,
        retryAt: Date,
        now: Date
    ) {
        if automaticReconnectRetryTask != nil,
           automaticReconnectRetryAccountID == accountID,
           automaticReconnectRetryAt == retryAt {
            return
        }
        automaticReconnectRetryTask?.cancel()
        automaticReconnectRetryAccountID = accountID
        automaticReconnectRetryAt = retryAt
        let delay = max(0, retryAt.timeIntervalSince(now))
        automaticReconnectRetryTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.reconnectScopeMatches(accountID),
                  self.automaticReconnectBackoffOwner.accountID == accountID,
                  self.automaticReconnectRetryAccountID == accountID,
                  self.automaticReconnectRetryAt == retryAt else { return }
            self.automaticReconnectRetryTask = nil
            self.automaticReconnectRetryAccountID = nil
            self.automaticReconnectRetryAt = nil
            guard self.connectionState != .connected else { return }
            let currentNow = self.runtime?.now() ?? Date()
            if self.automaticReconnectBackoffOwner.isBlocked(
                accountID: accountID,
                now: currentNow
            ), let nextRetryAt = self.automaticReconnectBackoffOwner.retryAt {
                self.scheduleAutomaticReconnectRetry(
                    accountID: accountID,
                    retryAt: nextRetryAt,
                    now: currentNow
                )
                return
            }
            self.recoverMobileConnection(trigger: .automaticBackoffExpired)
        }
    }

    /// Connect the live session to a specific registry app instance (a tag on a
    /// device) using that instance's advertised routes.
    ///
    /// This is the device tree's tap-to-open for a tag that is not the currently
    /// connected one. It stages the exact Mac-and-instance DeviceLink request
    /// through the stored-route path, promotes it only after authentication and
    /// host-status verification, then refreshes the paired-Mac list. A rejected
    /// candidate leaves the healthy foreground connection untouched.
    /// - Parameters:
    ///   - device: The registry device the instance belongs to.
    ///   - instance: The tag/app-instance to connect to.
    public func connectToRegistryInstance(
        device: RegistryDevice,
        instance: RegistryAppInstance
    ) async {
        let scope = await currentScopeSnapshot()
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let candidateRoutes = Self.storedReconnectRoutes(
            instance.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard !candidateRoutes.isEmpty else {
            mobileShellLog.error(
                "connectToRegistryInstance: no reconnectable route device=\(device.deviceId, privacy: .public) tag=\(instance.tag, privacy: .public)"
            )
            return
        }
        if connectionState == .connected,
           connectedMacDeviceID == device.deviceId,
           activeMacInstanceTag == instance.tag,
           let liveRoute = activeRoute,
           candidateRoutes.contains(where: {
               $0.id == liveRoute.id || $0.endpoint == liveRoute.endpoint
           }) {
            return
        }
        let previousActive = pairedMacs.first { $0.isActive }
        let connectedRoute = (await connectStoredMacOutcome(
            name: device.displayName ?? device.deviceId,
            routes: candidateRoutes,
            pairedMacDeviceID: device.deviceId,
            instanceTagExpectation: .require(instance.tag)
        )).didConnect
        guard connectedRoute else {
            if previousActive != nil, connectionState != .connected {
                _ = await reconnectActiveMacIfAvailable(stackUserID: identityProvider?.currentUserID)
            }
            return
        }
        if let scope, await !isScopeCurrent(scope) { return }
        await loadPairedMacs()
        await loadRegistryDevices()
    }

    /// Connect a live account-discovered Iroh Mac while requiring its broker
    /// advertised app-instance tag.
    @discardableResult
    func connectAccountDiscoveredIrohMac(
        _ mac: MobileDiscoveredIrohMac,
        accountID: String,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let candidateRoutes = Self.storedReconnectRoutes(
            mac.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard candidateRoutes.contains(where: { $0.kind == .iroh }) else { return false }
        return (await connectStoredMacOutcome(
            name: mac.displayName ?? mac.deviceID,
            routes: candidateRoutes,
            pairedMacDeviceID: mac.deviceID,
            instanceTagExpectation: .require(mac.instanceTag),
            automaticReconnectAccountID: accountID,
            ifStillCurrent: ifStillCurrent
        )).didConnect
    }

    /// Re-fetch the authoritative workspace list from the connected Mac and apply
    /// it, awaiting the round-trip to completion.
    @discardableResult
    func reloadWorkspaceListFromMac(
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        guard let client = remoteClient else { return false }
        // While state sync v2 owns the list, do not build/serialize/send the
        // legacy full list at all (the Computers screen refreshes through here
        // every 10s; paying the full-list cost and discarding it defeats the
        // delta protocol). The cursor fetch is both the liveness probe and the
        // authoritative refresh, AWAITED so pull-to-refresh cannot report done
        // before state applied, with the caller's probe timeout honored.
        if stateSyncActive {
            return await performStateSyncFetch(client: client, timeoutNanoseconds: timeoutNanoseconds)
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.workspace.list",
                params: [:]
            )
            let data = try await client.sendRequest(
                request,
                timeoutNanoseconds: timeoutNanoseconds ?? runtime?.rpcRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(data)
            guard remoteClient === client, connectionState == .connected else { return false }
            // Re-check authority AFTER the await: negotiation can grant v2 in
            // the window while this legacy request was in flight, and applying
            // the captured full list then would overwrite newer mirror state.
            // The round-trip already proved liveness; the v2 mirror owns the
            // list, so report success without applying.
            if stateSyncActive { return true }
            applyRemoteWorkspaceList(response, preferActiveTicketTarget: false)
            syncSelectedTerminalForWorkspace()
            return true
        } catch {
            mobileShellLog.error(
                "workspace list event refresh failed: \(String(describing: error), privacy: .private)"
            )
            if remoteClient === client {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return false
        }
    }

    /// - Parameter pairedMacDeviceID: the REAL paired-Mac device id when the caller
    ///   knows it (switch/reconnect/device-row paths). Passing the real id keys
    ///   foreground aggregate state under it instead of any compatibility id.
    ///   `nil` only when the host identity is genuinely unknown.

    /// Races `operation` against a wall-clock deadline. Returns the
    /// operation's value, or `nil` when the deadline expires first.
    ///
    /// Deliberately UNSTRUCTURED: a task group would structurally await the
    /// losing child, so a dial that ignores cancellation (the exact wedge
    /// this exists for) would suspend the race forever. Instead the
    /// operation runs in its own task that the deadline path abandons after
    /// a best-effort cancel; the once-guard is MainActor-confined so exactly
    /// one side resumes. An abandoned dial retains its captures until it
    /// eventually resolves — bounded by transport teardown and precisely the
    /// cost of not being wedged.
    /// Ceiling on concurrently outstanding abandoned (wedged) dials before
    /// automatic retries pause. A dial that resolves reclaims its slot and
    /// re-arms the automatic retry when still disconnected.
    static var maximumAbandonedReconnectDials: Int { 3 }

    static func shouldRecordReconnectBackoff(
        abandonedDialCount: Int
    ) -> Bool {
        abandonedDialCount < maximumAbandonedReconnectDials
    }

    /// Tracks an abandoned dial until it resolves, so a persistently wedged
    /// transport cannot accumulate an unbounded set of retained reconnect
    /// tasks across automatic retries. On resolution, if the shell is still
    /// signed in and disconnected, the automatic retry loop is re-armed
    /// (covers the case where retries were paused at the ceiling).
    func registerAbandonedReconnectDial(_ task: Task<StoredMacReconnectOutcome, Never>?) {
        guard let task else { return }
        abandonedReconnectDialCount += 1
        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self else { return }
            self.abandonedReconnectDialCount = max(0, self.abandonedReconnectDialCount - 1)
            // Re-arm the retry loop directly through the coalesced recovery
            // entry, NEVER by recording backoff: a backoff write here can land
            // mid-manual-retry and re-block the dial the user just requested
            // (manual retries clear backoff on entry). Skip when any attempt
            // or scheduled retry is already active.
            guard self.reconnectBackoffScopeID() != nil,
                  self.connectionState != .connected,
                  !self.connectionRecoveryOwner.isRedialingOrValidating,
                  self.automaticReconnectRetryTask == nil else { return }
            self.recoverMobileConnection(trigger: .automaticBackoffExpired)
        }
    }

    /// The race result: `value` is nil when the deadline won, in which case
    /// `abandoned` is the still-running operation task so the caller can
    /// bound how many abandoned dials may exist at once and reclaim the slot
    /// when the task eventually resolves.
    struct DeadlineRaceOutcome<Value: Sendable>: Sendable {
        let value: Value?
        let abandoned: Task<Value, Never>?
        let didTimeOut: Bool
        let wasCancelled: Bool
    }

    static func raceAgainstDeadline<Value: Sendable>(
        nanoseconds: UInt64,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> DeadlineRaceOutcome<Value> {
        let operationTask = Task { await operation() }
        // RPCTaskTimeout owns the deadline race through an actor. Keep the
        // operation itself separate so a cancellation-ignoring FFI dial does
        // not park the timeout scheduler; the returned handle accounts for
        // that abandoned work until it eventually resolves.
        let deadlineWaiter = Task<Value, any Error> {
            await operationTask.value
        }
        let value: Value?
        let didTimeOut: Bool
        let wasCancelled: Bool
        do {
            value = try await RPCTaskTimeout().value(
                deadlineWaiter,
                timeoutNanoseconds: nanoseconds
            )
            didTimeOut = false
            wasCancelled = false
        } catch {
            deadlineWaiter.cancel()
            operationTask.cancel()
            value = nil
            wasCancelled = Task.isCancelled || error is CancellationError
            didTimeOut = !wasCancelled
        }
        return DeadlineRaceOutcome(
            value: value,
            abandoned: value == nil ? operationTask : nil,
            didTimeOut: didTimeOut,
            wasCancelled: wasCancelled
        )
    }
}
