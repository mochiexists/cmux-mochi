import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileShell
public import CmuxMobileShellModel
public import Observation

/// Mac-facing adapter over the shared MobileShell connection engine.
@MainActor
@Observable
public final class HiveWorkspaceCoordinator {
    private static let statusReconnectDeadlineNanoseconds: UInt64 = 10_000_000_000

    /// Empty-list presentation for the Remote Macs browser.
    public enum EmptyState: Equatable, Sendable {
        case neverPaired
        case pairedOffline
        case noWorkspaces
    }

    /// User-visible state for pairing and reconnect surfaces.
    public enum Phase: Equatable, Sendable {
        case idle
        case pairing
        case connecting
        case connected
        case pairedOffline(message: String, guidance: String?)
        case failed(message: String, guidance: String?)
    }

    public private(set) var phase: Phase = .idle
    /// Latest immutable workspace projection from the shared shell engine.
    public private(set) var workspaces: [MobileWorkspacePreview]
    /// Durable remote-Mac pairings, including offline Macs with no workspace snapshot.
    public private(set) var pairedMacs: [MobilePairedMac]
    /// Human-readable route/recovery detail shown under the lifecycle status.
    public private(set) var connectionDetail: String?
    public var hasKnownPairing: Bool { shell.hasKnownHivePairing }
    /// The empty state to render, or `nil` while remote workspaces are available.
    public var emptyState: EmptyState? {
        guard workspaces.isEmpty else { return nil }
        guard hasKnownPairing || !pairedMacs.isEmpty else { return .neverPaired }
        let hasOnlineMac = pairedMacs.contains {
            connectionStatus(for: $0) == .connected
        }
        return hasOnlineMac || shell.hiveConnectionState == .connected
            ? .noWorkspaces
            : .pairedOffline
    }

    @ObservationIgnored private let shell: any HiveShellServing
    @ObservationIgnored private let pairingLinkDecoder: HivePairingLinkDecoder
    @ObservationIgnored private let lifecycleClock: any Clock<Duration>
    @ObservationIgnored private let lifecyclePollInterval: Duration
    @ObservationIgnored private let lifecycleIdlePollInterval: Duration
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleStartInProgress = false
    @ObservationIgnored private var reconnectInProgress = false
    @ObservationIgnored private var isBrowserVisible = false
    @ObservationIgnored private var mountedWorkspaceCount = 0

    /// Creates a Hive coordinator over the shared mobile-shell engine.
    ///
    /// - Parameters:
    ///   - shell: Connection and workspace capability used by Hive.
    ///   - pairingLinkDecoder: Decoder for current DeviceLink pairing URLs.
    ///   - lifecycleClock: Clock that schedules background snapshot refreshes.
    ///   - lifecyclePollInterval: Delay while Hive UI is actively in use.
    ///   - lifecycleIdlePollInterval: Delay while Hive has no visible or mounted UI.
    public init(
        shell: any HiveShellServing,
        pairingLinkDecoder: HivePairingLinkDecoder = HivePairingLinkDecoder(),
        lifecycleClock: any Clock<Duration> = ContinuousClock(),
        lifecyclePollInterval: Duration = .seconds(1),
        lifecycleIdlePollInterval: Duration = .seconds(30)
    ) {
        self.shell = shell
        self.pairingLinkDecoder = pairingLinkDecoder
        self.lifecycleClock = lifecycleClock
        self.lifecyclePollInterval = lifecyclePollInterval
        self.lifecycleIdlePollInterval = lifecycleIdlePollInterval
        workspaces = shell.workspaces
        pairedMacs = shell.hivePairedMacs
        connectionDetail = nil
    }

    deinit {
        lifecycleTask?.cancel()
    }

    /// Starts app-lifetime reconnect and snapshot monitoring when a pairing exists.
    public func startConnectionLifecycle() async {
        guard lifecycleTask == nil, !lifecycleStartInProgress else { return }
        lifecycleStartInProgress = true
        defer { lifecycleStartInProgress = false }

        if !hasKnownPairing {
            await shell.loadPairedMacs()
            refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        }
        guard hasKnownPairing else { return }

        _ = await reconnect()
        startSnapshotPollingIfNeeded()
    }

    /// Stops background Hive snapshot monitoring.
    public func stopConnectionLifecycle() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    /// Reports whether the Remote Macs browser is currently visible.
    public func setBrowserVisible(_ visible: Bool) {
        guard isBrowserVisible != visible else { return }
        isBrowserVisible = visible
        restartSnapshotPollingIfNeeded()
    }

    /// Reports how many local Hive workspaces are currently mounted.
    public func setMountedWorkspaceCount(_ count: Int) {
        let count = max(0, count)
        guard mountedWorkspaceCount != count else { return }
        mountedWorkspaceCount = count
        restartSnapshotPollingIfNeeded()
    }

    /// Returns the live connection state for one exact paired app instance.
    public func connectionStatus(for mac: MobilePairedMac) -> MobileMacConnectionStatus {
        if let exact = shell.hiveMacConnectionStatuses[mac.id] {
            return exact
        }
        if let device = shell.hiveMacConnectionStatuses[mac.macDeviceID] {
            return device
        }
        if mac.isActive {
            return shell.hiveMacConnectionStatus
        }
        return .unavailable
    }

    /// Connects one selected paired Mac and refreshes its projected state.
    public func connect(_ mac: MobilePairedMac) async {
        await shell.reconnectHiveMac(
            macDeviceID: mac.macDeviceID,
            instanceTag: mac.instanceTag
        )
        await shell.loadPairedMacs()
        refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
    }

    /// Create a renderer adapter for one terminal exposed by the shell.
    public func makeTerminalSession(surfaceID: String) -> HiveTerminalSession? {
        guard let terminalShell = shell as? any HiveTerminalShellServing else {
            return nil
        }
        return HiveTerminalSession(surfaceID: surfaceID, shell: terminalShell)
    }

    /// Creates a terminal through the same authenticated host RPC used by iOS.
    public func createTerminal(in workspaceID: MobileWorkspacePreview.ID) {
        shell.createTerminal(in: workspaceID)
    }

    /// Renames a workspace through the authenticated host workspace-action RPC.
    @discardableResult
    public func renameWorkspace(
        id: MobileWorkspacePreview.ID,
        title: String
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let result = await shell.renameWorkspace(
            id: id,
            title: title,
            refreshAfterMutation: true
        )
        refreshWorkspaceSnapshot()
        return result
    }

    /// Pair using the host's DeviceLink v3 URL and expose the shell result.
    @discardableResult
    public func pair(link: String) async -> Bool {
        do {
            _ = try pairingLinkDecoder.decode(link)
        } catch {
            phase = .failed(
                message: String(
                    localized: "hive.error.invalidLink.message",
                    defaultValue: "This is not a current Mochi pairing link."
                ),
                guidance: String(
                    localized: "hive.error.invalidLink.guidance",
                    defaultValue: "Open Pair a Device on the remote Mac and paste its new link."
                )
            )
            return false
        }

        phase = .pairing
        let result = await shell.connectPairingURLResult(link)
        guard result.didPair else {
            phase = .failed(
                message: shell.connectionError ?? String(
                    localized: "hive.error.pairing",
                    defaultValue: "Could not pair with the remote Mac."
                ),
                guidance: shell.connectionErrorGuidance
            )
            return false
        }
        await shell.loadPairedMacs()
        refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        startSnapshotPollingIfNeeded()
        return true
    }

    /// Reconnect every DeviceLink pairing from local storage.
    @discardableResult
    public func reconnect() async -> Bool {
        await reconnect(attemptDeadlineNanoseconds: nil)
    }

    /// Reconnects for a status request using a deadline shorter than the
    /// control-socket request timeout, leaving time to return offline state.
    @discardableResult
    public func reconnectForStatus() async -> Bool {
        await reconnect(
            attemptDeadlineNanoseconds: Self.statusReconnectDeadlineNanoseconds
        )
    }

    private func reconnect(attemptDeadlineNanoseconds: UInt64?) async -> Bool {
        guard hasKnownPairing else {
            phase = .idle
            return false
        }
        guard !reconnectInProgress else { return shell.isHiveMacConnected }
        reconnectInProgress = true
        defer { reconnectInProgress = false }

        phase = .connecting
        let connected = await shell.reconnectAllPairedMacs(
            stackUserID: nil,
            refreshBackupBeforeDial: false,
            attemptDeadlineNanoseconds: attemptDeadlineNanoseconds
        )
        await shell.loadPairedMacs()
        refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        return connected
    }

    /// Refreshes both data and connection lifecycle after shell state changes.
    public func refreshWorkspaceSnapshot(forcePhaseReconciliation: Bool = false) {
        let latest = shell.workspaces
        if workspaces != latest {
            workspaces = latest
        }
        let latestPairings = shell.hivePairedMacs
        if pairedMacs != latestPairings {
            pairedMacs = latestPairings
        }
        reconcileConnectionPhase(force: forcePhaseReconciliation)
    }

    /// Removes a pairing, revoking it remotely when reachable.
    public func removePairing(
        _ mac: MobilePairedMac,
        localOnly: Bool = false
    ) async -> MobileComputerRemovalResult {
        let aliasIDs = pairedMacs
            .filter {
                $0.macDeviceID == mac.macDeviceID
                    && $0.instanceTag == mac.instanceTag
            }
            .map(\.id)
        let result: MobileComputerRemovalResult
        if localOnly {
            result = await shell.removeComputerLocally(
                representativeID: mac.id,
                aliasIDs: aliasIDs
            ) ? .removed : .failed
        } else {
            result = await shell.removeComputer(
                representativeID: mac.id,
                aliasIDs: aliasIDs
            )
        }
        if result == .removed {
            await shell.loadPairedMacs()
            refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
            if !hasKnownPairing {
                stopConnectionLifecycle()
            }
        }
        return result
    }

    private func startSnapshotPollingIfNeeded() {
        guard lifecycleTask == nil else { return }
        let clock = lifecycleClock
        lifecycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.snapshotPollInterval
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                await Task.yield()
                self.refreshWorkspaceSnapshot()
            }
        }
    }

    private var snapshotPollInterval: Duration {
        isBrowserVisible || mountedWorkspaceCount > 0
            ? lifecyclePollInterval
            : lifecycleIdlePollInterval
    }

    private func restartSnapshotPollingIfNeeded() {
        guard lifecycleTask != nil else { return }
        lifecycleTask?.cancel()
        lifecycleTask = nil
        startSnapshotPollingIfNeeded()
    }

    private func reconcileConnectionPhase(force: Bool) {
        if !force, case .pairing = phase { return }

        if shell.hiveConnectionState == .connected {
            phase = .connected
            connectionDetail = routeDetail(prefix: String(
                localized: "hive.route.connected",
                defaultValue: "Connected over"
            ))
            return
        }
        if shell.hiveIsReconnecting || shell.hiveMacConnectionStatus == .reconnecting {
            phase = .connecting
            connectionDetail = routeDetail(prefix: String(
                localized: "hive.route.trying",
                defaultValue: "Trying"
            )) ?? String(
                localized: "hive.route.recovering",
                defaultValue: "Recovering the authenticated connection"
            )
            return
        }
        connectionDetail = routeDetail(prefix: String(
            localized: "hive.route.lastTried",
            defaultValue: "Last tried"
        ))
        if hasKnownPairing {
            phase = .pairedOffline(
                message: shell.connectionError ?? String(
                    localized: "hive.error.offline",
                    defaultValue: "The remote Mac is offline."
                ),
                guidance: shell.connectionErrorGuidance
            )
        } else if force {
            phase = .idle
        }
    }

    private func routeDetail(prefix: String) -> String? {
        guard let route = shell.hiveActiveRoute else { return nil }
        let transport = switch route.kind {
        case .localNetwork:
            String(localized: "hive.route.local", defaultValue: "local network")
        case .tailscale:
            String(localized: "hive.route.tailscale", defaultValue: "Tailscale")
        case .debugLoopback:
            String(localized: "hive.route.loopback", defaultValue: "local loopback")
        case .iroh:
            String(localized: "hive.route.iroh", defaultValue: "Iroh")
        case .websocket:
            String(localized: "hive.route.websocket", defaultValue: "WebSocket")
        }
        guard case let .hostPort(host, port) = route.endpoint else {
            return "\(prefix) \(transport)"
        }
        return "\(prefix) \(transport) (\(host):\(port))"
    }
}
