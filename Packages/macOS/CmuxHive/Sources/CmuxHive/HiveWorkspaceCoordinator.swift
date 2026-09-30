import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileShell
public import CmuxMobileShellModel
public import Observation

/// Mac-facing adapter over the shared MobileShell connection engine.
@MainActor
@Observable
public final class HiveWorkspaceCoordinator {
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

    @ObservationIgnored private let shell: any HiveShellServing
    @ObservationIgnored private let pairingLinkDecoder: HivePairingLinkDecoder
    @ObservationIgnored private let lifecycleClock: any Clock<Duration>
    @ObservationIgnored private let lifecyclePollInterval: Duration
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleStartInProgress = false

    /// Creates a Hive coordinator over the shared mobile-shell engine.
    ///
    /// - Parameters:
    ///   - shell: Connection and workspace capability used by Hive.
    ///   - pairingLinkDecoder: Decoder for current DeviceLink pairing URLs.
    ///   - lifecycleClock: Clock that schedules background snapshot refreshes.
    ///   - lifecyclePollInterval: Delay between background snapshot refreshes.
    public init(
        shell: any HiveShellServing,
        pairingLinkDecoder: HivePairingLinkDecoder = HivePairingLinkDecoder(),
        lifecycleClock: any Clock<Duration> = ContinuousClock(),
        lifecyclePollInterval: Duration = .seconds(1)
    ) {
        self.shell = shell
        self.pairingLinkDecoder = pairingLinkDecoder
        self.lifecycleClock = lifecycleClock
        self.lifecyclePollInterval = lifecyclePollInterval
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
        guard hasKnownPairing else {
            phase = .idle
            return false
        }
        phase = .connecting
        let connected = await shell.reconnectAllPairedMacs(
            stackUserID: nil,
            refreshBackupBeforeDial: false
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
        let interval = lifecyclePollInterval
        lifecycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                await Task.yield()
                guard let self else { return }
                self.refreshWorkspaceSnapshot()
            }
        }
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
