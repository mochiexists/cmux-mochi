import CMUXMobileCore
import CmuxMobileShell
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxHive

@MainActor
@Suite("Hive workspace coordinator")
struct HiveWorkspaceCoordinatorTests {
    @Test("pairs through the shell and exposes its remote workspaces")
    func pairsAndExposesWorkspaces() async throws {
        let workspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Mochi",
            terminals: [MobileTerminalPreview(id: "terminal-a", name: "Shell")]
        )
        let shell = HiveShellStub(
            pairingResult: .connected,
            workspaces: [workspace],
            isConnected: true
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        let paired = await coordinator.pair(
            link: Self.deviceLinkURL
        )

        #expect(paired)
        #expect(coordinator.phase == .connected)
        #expect(coordinator.workspaces == [workspace])
        #expect(shell.receivedPairingLinks == [Self.deviceLinkURL])
    }

    @Test("reports a saved pairing as offline when its first dial fails")
    func reportsPairedOffline() async {
        let shell = HiveShellStub(
            pairingResult: .pairedOffline,
            workspaces: [],
            connectionError: "Connection refused",
            connectionErrorGuidance: "Open the remote app.",
            hasKnownPairing: true,
            isConnected: false
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        let paired = await coordinator.pair(link: Self.deviceLinkURL)

        #expect(paired)
        #expect(coordinator.phase == .pairedOffline(
            message: "Connection refused",
            guidance: "Open the remote app."
        ))
    }

    @Test("does not attempt reconnect before any Mac has been paired")
    func skipsReconnectWithoutPairing() async {
        let shell = HiveShellStub(pairingResult: .failed, workspaces: [])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(await !coordinator.reconnect())
        #expect(coordinator.phase == .idle)
        #expect(shell.reconnectCount == 0)
    }

    @Test("reports a known paired Mac as offline when reconnect fails")
    func reportsReconnectAsPairedOffline() async {
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            connectionError: "Connection refused",
            connectionErrorGuidance: "Open the remote app.",
            hasKnownPairing: true,
            isConnected: false
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(await !coordinator.reconnect())
        #expect(coordinator.phase == .pairedOffline(
            message: "Connection refused",
            guidance: "Open the remote app."
        ))
    }

    @Test("reconnects every paired Mac instead of only the active Mac")
    func reconnectsEveryPairedMac() async {
        let pairedMacs = [
            Self.pairedMac(deviceID: "mac-a", displayName: "Studio", isActive: true),
            Self.pairedMac(deviceID: "mac-b", displayName: "Laptop", isActive: false),
        ]
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            isConnected: true,
            pairedMacs: pairedMacs
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(await coordinator.reconnect())
        #expect(shell.reconnectedPairingIDs == pairedMacs.map(\.id))
    }

    @Test("owns reconnect and snapshot polling without the browser window")
    func ownsConnectionLifecycle() async {
        let updatedWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Updated",
            terminals: []
        )
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            isConnected: true,
            pairedMacs: [Self.pairedMac(
                deviceID: "mac-a",
                displayName: "Studio",
                isActive: true
            )]
        )
        let coordinator = HiveWorkspaceCoordinator(
            shell: shell,
            lifecyclePollInterval: .zero,
            lifecycleIdlePollInterval: .zero
        )

        await coordinator.startConnectionLifecycle()
        shell.workspaces = [updatedWorkspace]
        await Self.yieldUntil {
            coordinator.workspaces == [updatedWorkspace]
        }
        coordinator.stopConnectionLifecycle()

        #expect(shell.reconnectedPairingIDs == shell.hivePairedMacs.map(\.id))
        #expect(coordinator.workspaces == [updatedWorkspace])
    }

    @Test("projects distinct Remote Macs empty states")
    func projectsDistinctEmptyStates() {
        let neverPaired = HiveWorkspaceCoordinator(
            shell: HiveShellStub(pairingResult: .failed, workspaces: [])
        )
        #expect(neverPaired.emptyState == .neverPaired)

        let pairedMac = Self.pairedMac(
            deviceID: "mac-a",
            displayName: "Studio",
            isActive: true
        )
        let pairedOffline = HiveWorkspaceCoordinator(shell: HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            pairedMacs: [pairedMac],
            connectionStatuses: [pairedMac.id: .unavailable]
        ))
        #expect(pairedOffline.emptyState == .pairedOffline)

        let connectedWithoutWorkspaces = HiveWorkspaceCoordinator(shell: HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            isConnected: true,
            pairedMacs: [pairedMac],
            connectionStatuses: [pairedMac.id: .connected]
        ))
        #expect(connectedWithoutWorkspaces.emptyState == .noWorkspaces)
    }

    @Test("exposes exact per-Mac status and connects the selected Mac")
    func connectsSelectedMac() async {
        let studio = Self.pairedMac(deviceID: "mac-a", displayName: "Studio", isActive: true)
        let laptop = Self.pairedMac(deviceID: "mac-b", displayName: "Laptop", isActive: false)
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            pairedMacs: [studio, laptop],
            connectionStatuses: [
                studio.id: .connected,
                laptop.id: .unavailable,
            ]
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(coordinator.connectionStatus(for: studio) == .connected)
        #expect(coordinator.connectionStatus(for: laptop) == .unavailable)
        await coordinator.connect(laptop)

        #expect(shell.reconnectToMacRequests == [
            .init(deviceID: laptop.macDeviceID, instanceTag: laptop.instanceTag),
        ])
    }

    @Test("keeps pairing phase observable until the pairing request settles")
    func pairingPhaseRemainsObservable() async {
        let shell = HiveShellStub(
            pairingResult: .connected,
            workspaces: [],
            pairingIsSuspended: true
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        let pairingTask = Task { await coordinator.pair(link: Self.deviceLinkURL) }
        await shell.waitUntilPairingStarts()
        #expect(coordinator.phase == .pairing)

        shell.resumePairing()
        #expect(await pairingTask.value)
    }

    @Test("polls slowly when idle and quickly while the browser or a mirror is active")
    func adaptsSnapshotPollingToVisibleActivity() async {
        let pairedMac = Self.pairedMac(
            deviceID: "mac-a",
            displayName: "Studio",
            isActive: true
        )
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            isConnected: true,
            pairedMacs: [pairedMac]
        )
        let clock = HiveManualTestClock()
        let coordinator = HiveWorkspaceCoordinator(
            shell: shell,
            lifecycleClock: clock,
            lifecyclePollInterval: .seconds(1),
            lifecycleIdlePollInterval: .seconds(30)
        )

        await coordinator.startConnectionLifecycle()
        await clock.waitUntilSleepCount(1)
        #expect(clock.requestedDurations == [.seconds(30)])

        coordinator.setBrowserVisible(true)
        await clock.waitUntilSleepCount(2)
        #expect(clock.requestedDurations.suffix(1) == [.seconds(1)])

        coordinator.setBrowserVisible(false)
        coordinator.setMountedWorkspaceCount(1)
        await clock.waitUntilSleepCount(3)
        #expect(clock.requestedDurations.suffix(1) == [.seconds(1)])

        coordinator.setMountedWorkspaceCount(0)
        await clock.waitUntilSleepCount(4)
        #expect(clock.requestedDurations.suffix(1) == [.seconds(30)])
        coordinator.stopConnectionLifecycle()
    }

    @Test("refresh projects reconnect and offline lifecycle truthfully")
    func refreshProjectsConnectionLifecycle() throws {
        let route = try CmxAttachRoute(
            id: "lan",
            kind: .localNetwork,
            endpoint: .hostPort(host: "studio-mac.local", port: 39_939),
            priority: 5
        )
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            isConnected: true,
            activeRoute: route
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        coordinator.refreshWorkspaceSnapshot()
        #expect(coordinator.phase == .connected)
        #expect(coordinator.connectionDetail?.contains("studio-mac.local:39939") == true)

        shell.isHiveMacConnected = false
        shell.hiveConnectionState = .disconnected
        shell.hiveMacConnectionStatus = .reconnecting
        shell.hiveIsReconnecting = true
        coordinator.refreshWorkspaceSnapshot()
        #expect(coordinator.phase == .connecting)

        shell.hiveMacConnectionStatus = .unavailable
        shell.hiveIsReconnecting = false
        coordinator.refreshWorkspaceSnapshot()
        guard case .pairedOffline = coordinator.phase else {
            Issue.record("Expected paired-offline phase")
            return
        }
    }

    @Test("remove exposes local-only confirmation then deletes exact pairing")
    func removesPairingLocallyAfterConfirmation() async {
        let mac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: true,
            stackUserID: nil,
            instanceTag: "nightly"
        )
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            pairedMacs: [mac],
            removalResult: .requiresLocalOnlyConfirmation
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(await coordinator.removePairing(mac) == .requiresLocalOnlyConfirmation)
        #expect(await coordinator.removePairing(mac, localOnly: true) == .removed)
        #expect(shell.localRemovalIDs == [mac.id])
    }

    @Test("routes supported workspace mutations through the mobile host RPCs")
    func routesWorkspaceMutations() async {
        let workspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: []
        )
        let shell = HiveShellStub(pairingResult: .connected, workspaces: [workspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        coordinator.createTerminal(in: workspace.rpcWorkspaceID)
        let result = await coordinator.renameWorkspace(
            id: workspace.rpcWorkspaceID,
            title: "Renamed"
        )

        #expect(shell.createdTerminalWorkspaceIDs == [workspace.rpcWorkspaceID])
        #expect(shell.workspaceRenameRequests == [
            .init(id: workspace.rpcWorkspaceID, title: "Renamed", refreshAfterMutation: true),
        ])
        guard case .success = result else {
            Issue.record("Expected successful workspace rename")
            return
        }
    }

    private static let deviceLinkURL =
        "cmux-ios-dev://attach?v=3&r=192.168.1.25:3939"
        + "&f=" + String(repeating: "ab", count: 32)
        + "&t=single-use-ticket&n=Studio"

    private static func pairedMac(
        deviceID: String,
        displayName: String,
        isActive: Bool
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: deviceID,
            displayName: displayName,
            routes: [],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: isActive,
            stackUserID: nil,
            instanceTag: "nightly"
        )
    }

    private static func yieldUntil(
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never became true", sourceLocation: sourceLocation)
    }
}

@MainActor
private final class HiveShellStub: HiveShellServing {
    struct ReconnectRequest: Equatable {
        let deviceID: String
        let instanceTag: String?
    }

    let pairingResult: MobilePairingURLConnectionResult
    var workspaces: [MobileWorkspacePreview]
    var connectionError: String?
    var connectionErrorGuidance: String?
    var hasKnownHivePairing: Bool
    var isHiveMacConnected: Bool
    var hiveConnectionState: MobileConnectionState
    var hiveMacConnectionStatus: MobileMacConnectionStatus
    var hiveIsReconnecting: Bool
    var hiveActiveRoute: CmxAttachRoute?
    var hivePairedMacs: [MobilePairedMac]
    var hiveMacConnectionStatuses: [String: MobileMacConnectionStatus]
    var removalResult: MobileComputerRemovalResult
    private(set) var receivedPairingLinks: [String] = []
    private(set) var reconnectCount = 0
    private(set) var reconnectedPairingIDs: [String] = []
    private(set) var localRemovalIDs: [String] = []
    private(set) var createdTerminalWorkspaceIDs: [MobileWorkspacePreview.ID?] = []
    private(set) var workspaceRenameRequests: [WorkspaceRenameRequest] = []
    private(set) var reconnectToMacRequests: [ReconnectRequest] = []
    private var pairingContinuation: CheckedContinuation<Void, Never>?
    private var pairingStartContinuation: CheckedContinuation<Void, Never>?
    private var pairingStarted = false
    private let pairingIsSuspended: Bool

    struct WorkspaceRenameRequest: Equatable {
        let id: MobileWorkspacePreview.ID
        let title: String
        let refreshAfterMutation: Bool
    }

    init(
        pairingResult: MobilePairingURLConnectionResult,
        workspaces: [MobileWorkspacePreview],
        connectionError: String? = nil,
        connectionErrorGuidance: String? = nil,
        hasKnownPairing: Bool = false,
        isConnected: Bool = false,
        activeRoute: CmxAttachRoute? = nil,
        pairedMacs: [MobilePairedMac] = [],
        connectionStatuses: [String: MobileMacConnectionStatus] = [:],
        pairingIsSuspended: Bool = false,
        removalResult: MobileComputerRemovalResult = .removed
    ) {
        self.pairingResult = pairingResult
        self.workspaces = workspaces
        self.connectionError = connectionError
        self.connectionErrorGuidance = connectionErrorGuidance
        self.hasKnownHivePairing = hasKnownPairing
        self.isHiveMacConnected = isConnected
        hiveConnectionState = isConnected ? .connected : .disconnected
        hiveMacConnectionStatus = isConnected ? .connected : .unavailable
        hiveIsReconnecting = false
        hiveActiveRoute = activeRoute
        hivePairedMacs = pairedMacs
        hiveMacConnectionStatuses = connectionStatuses
        self.pairingIsSuspended = pairingIsSuspended
        self.removalResult = removalResult
    }

    func connectPairingURLResult(
        _ rawValue: String?
    ) async -> MobilePairingURLConnectionResult {
        receivedPairingLinks.append(rawValue ?? "")
        pairingStarted = true
        pairingStartContinuation?.resume()
        pairingStartContinuation = nil
        if pairingIsSuspended {
            await withCheckedContinuation { continuation in
                pairingContinuation = continuation
            }
        }
        return pairingResult
    }

    func waitUntilPairingStarts() async {
        if pairingStarted { return }
        await withCheckedContinuation { continuation in
            pairingStartContinuation = continuation
        }
    }

    func resumePairing() {
        pairingContinuation?.resume()
        pairingContinuation = nil
    }

    func reconnectActiveMacIfAvailable(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool
    ) async -> Bool {
        reconnectCount += 1
        return isHiveMacConnected
    }

    func reconnectAllPairedMacs(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool
    ) async -> Bool {
        reconnectedPairingIDs = hivePairedMacs.map(\.id)
        return isHiveMacConnected
    }

    func reconnectHiveMac(macDeviceID: String, instanceTag: String?) async {
        reconnectToMacRequests.append(.init(
            deviceID: macDeviceID,
            instanceTag: instanceTag
        ))
    }

    func loadPairedMacs() async {}

    func createTerminal(in workspaceID: MobileWorkspacePreview.ID?) {
        createdTerminalWorkspaceIDs.append(workspaceID)
    }

    func renameWorkspace(
        id: MobileWorkspacePreview.ID,
        title: String,
        refreshAfterMutation: Bool
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        workspaceRenameRequests.append(.init(
            id: id,
            title: title,
            refreshAfterMutation: refreshAfterMutation
        ))
        return .success(())
    }

    func removeComputer(
        representativeID: String,
        aliasIDs: [String]
    ) async -> MobileComputerRemovalResult {
        removalResult
    }

    func removeComputerLocally(
        representativeID: String,
        aliasIDs: [String]
    ) async -> Bool {
        localRemovalIDs.append(representativeID)
        hivePairedMacs.removeAll { $0.id == representativeID }
        hasKnownHivePairing = !hivePairedMacs.isEmpty
        return true
    }
}

private final class HiveManualTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var sleepDurations: [Duration] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Instant {
        lock.withLock { currentInstant }
    }

    var minimumResolution: Duration { .zero }

    var requestedDurations: [Duration] {
        lock.withLock { sleepDurations }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledSleeperIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepDurations.append(currentInstant.duration(to: deadline))
                sleepers[id] = Sleeper(continuation: continuation)
                let ready = takeReadyWaitersLocked()
                lock.unlock()
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil { cancelledSleeperIDs.insert(id) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleepCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if sleepDurations.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((count, continuation))
            lock.unlock()
        }
    }

    private func takeReadyWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        var ready: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            guard sleepDurations.count >= waiter.count else { return false }
            ready.append(waiter.continuation)
            return true
        }
        return ready
    }
}
