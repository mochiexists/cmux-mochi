import CMUXMobileCore
import CmuxIrohTransport
import Foundation
@preconcurrency import Network
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
@Suite(.serialized)
@MainActor
struct MobileHostAuthorizationTests {

    /// Under XCTest the legacy listener must not start.
    ///
    /// Starting it reads this Mac's DeviceLink identity from the keychain
    /// synchronously on the main thread. Debug builds are ad-hoc signed, so
    /// every rebuild has a new code-signing hash and the keychain ACL treats it
    /// as a different app; securityd raises a confirmation dialog nobody answers
    /// under `xcodebuild test` and the host wedges before XCTest can connect
    /// ("The test runner hung before establishing connection"). The suite could
    /// not be run at all until this was fixed.
    ///
    /// The guard for this already existed but was unreachable: it lived only on
    /// the branch taken when the listener does *not* start, while the DEBUG
    /// default for `mobile.iOSPairingHost.enabled` is ON — precisely the case it
    /// was written to cover.
    @Test func testXCTestSuppressesLegacyListenerEvenWhenPairingDefaultsOn() {
        // The debug-default-ON state: enabled, not already running.
        #expect(
            MobileHostService.startupPlan(
                legacyListenerEnabled: true,
                legacyListenerRunning: false,
                suppressLegacyListenerForXCTest: true
            ).startsLegacyListener == false
        )
        // Iroh still comes up; only the keychain-touching listener is skipped.
        #expect(
            MobileHostService.startupPlan(
                legacyListenerEnabled: true,
                legacyListenerRunning: false,
                suppressLegacyListenerForXCTest: true
            ).activatesIroh
        )
        // Outside XCTest the default stays ON, so a dev Mac still advertises.
        #expect(
            MobileHostService.startupPlan(
                legacyListenerEnabled: true,
                legacyListenerRunning: false,
                suppressLegacyListenerForXCTest: false
            ).startsLegacyListener
        )
    }

    @Test func testAppHostMarkerSuppressesLegacyListenerBeforeXCTestConnects() {
        #expect(
            MobileHostService.shouldSuppressLegacyListenerForXCTest(
                environment: ["CMUX_TEST_PROCESS": "1"]
            )
        )
        #expect(
            !MobileHostService.shouldSuppressLegacyListenerForXCTest(
                environment: [:]
            )
        )
    }


    /// Fork (cmux Mochi): the pairing port must never silently move. A paired
    /// phone stores the `host:port` it was told; rebinding on an OS-assigned
    /// port leaves the Mac "running" at an address no phone has ever seen,
    /// which presents as an unreachable Mac rather than a moved one.
    ///
    /// Upstream deliberately does the opposite (it moves to a ready candidate
    /// port), so this is the assertion that catches the divergence being
    /// silently undone by a future rebase.
    @Test func testMobileHostBindFailureFailsClosedInsteadOfMovingPort() {
        let service = MobileHostService.shared
        let generation = UUID()
        // usesEphemeralFallback: false is the fixed pairing port -- the case
        // where the address is part of what a paired phone stored.
        service.debugSetListenerStateForTesting(
            generation: generation, usesEphemeralFallback: false, port: 58465
        )
        defer {
            service.debugSetListenerStateForTesting(
                generation: UUID(), usesEphemeralFallback: false, port: nil
            )
        }

        service.debugHandleListenerStateForTesting(
            .failed(.posix(.EADDRINUSE)), generation: generation
        )

        #expect(service.debugListenerPortForTesting() == nil)
    }

    /// A bind failure has to name the port to be actionable: the port is fixed
    /// by design, so the reader's next step is freeing that specific one.
    @Test func testMobileHostBindFailureNamesThePortAndTheLikelyCause() {
        let message = MobileHostService.bindFailureDescription(
            port: 58465, error: NWError.posix(.EADDRINUSE)
        )
        #expect(message.contains("58465"))
        #expect(message.lowercased().contains("already listening"))
    }


    @Test func testMobileHostRPCRejectsInvalidParamsShape() {
        let data = Data(#"{"id":"bad-params","method":"workspace.list","params":[]}"#.utf8)
        let result = MobileHostRPCEnvelope.decodeRequest(data)
        guard case let .failure(error) = result else {
            return #expect(Bool(false), "Invalid params shape should be rejected")
        }
        #expect(error.code == "invalid_request")
        #expect(error.message == "params must be an object")
    }
    @Test func testMobileHostRPCRejectsInvalidAuthShape() {
        let data = Data(#"{"id":"bad-auth","method":"workspace.list","auth":"token"}"#.utf8)
        let result = MobileHostRPCEnvelope.decodeRequest(data)
        guard case let .failure(error) = result else {
            return #expect(Bool(false), "Invalid auth shape should be rejected")
        }
        #expect(error.code == "invalid_request")
        #expect(error.message == "auth must be an object")
    }
    @Test func testMobileHostRPCIgnoresRefreshTokenOnlyAuth() {
        let data = Data(#"{"id":"refresh-only","method":"workspace.list","auth":{"stack_refresh_token":"secret"}}"#.utf8)
        let result = MobileHostRPCEnvelope.decodeRequest(data)
        guard case let .success(request) = result else {
            return #expect(Bool(false), "Refresh-token-only auth should decode as an unauthenticated request")
        }
        #expect(request.auth == nil)
    }
    @Test func testMobileRouteResolverPrioritizesNumericTailscaleAddressesBeforeMagicDNS() throws {
        let resolver = MobileRouteResolver()
        let snapshot = resolver.routes(
            port: 61234,
            tailscaleHosts: [
                "work-mac.tailnet.ts.net",
                "100.71.210.41",
                "fd7a:115c:a1e0::1234",
                "203.0.113.10",
            ]
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 3)
        #expect(tailscaleRoutes.first?.priority == 10)
        #expect(tailscaleRoutes[1].priority == 20)
        #expect(tailscaleRoutes.last?.priority == 100)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected first numeric Tailscale route")
        }
        if case let .hostPort(host, port) = tailscaleRoutes[1].endpoint {
            #expect(host == "fd7a:115c:a1e0::1234")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected IPv6 Tailscale route")
        }
        if case let .hostPort(host, port) = tailscaleRoutes.last?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected MagicDNS Tailscale route")
        }
    }
    @Test func testMobileRouteResolverImmediateSnapshotUsesNumericTailscaleFallbackWithoutDNS() throws {
        let resolver = MobileRouteResolver()
        let snapshot = resolver.routes(
            port: 61234,
            immediateHosts: {
                ["100.71.210.41"]
            }
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 1)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected immediate snapshot to include a numeric Tailscale route")
        }
        #expect(snapshot.routes.filter { $0.kind == .debugLoopback }.count == 1)
    }
    @Test func testMobileRouteResolverAwaitsMagicDNSForPublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()
        let snapshot = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            }
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 2)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected public status to publish the numeric Tailscale route")
        }
        if case let .hostPort(host, port) = tailscaleRoutes.last?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected public status to retain the MagicDNS route")
        }
    }
    @Test func testMobileRouteResolverRefreshesStalePublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()
        let now = Date()
        _ = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "old-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            },
            now: now
        )
        let refreshed = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "new-mac.tailnet.ts.net",
                    "100.71.210.42",
                ]
            },
            now: now.addingTimeInterval(31)
        )
        let tailscaleRoutes = refreshed.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.42")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected stale public status routes to refresh")
        }
    }
    @Test func testMobileRouteResolverRetriesAfterIPOnlyPublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()
        let now = Date()
        _ = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                ["100.71.210.41"]
            },
            now: now
        )
        let refreshed = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            },
            now: now.addingTimeInterval(1)
        )
        let tailscaleRoutes = refreshed.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected IP-only public status routes to retry MagicDNS resolution")
        }
    }
    @Test func testMobileRouteResolverNotifiesCallbackForInFlightMagicDNSRefresh() async throws {
        let resolver = MobileRouteResolver()
        let started = AsyncTestSignal()
        let callback = AsyncTestSignal()
        let gate = SendableSemaphore(value: 0)
        let observedHosts = LockedHosts()
        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                started.fulfill()
                gate.wait()
                return [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            }
        )
        try await started.wait()
        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                ["unused.tailnet.ts.net"]
            },
            onResolvedHosts: { hosts in
                observedHosts.set(hosts)
                callback.fulfill()
            }
        )
        gate.signal()
        try await callback.wait()
        #expect(observedHosts.value() == [
            "work-mac.tailnet.ts.net",
            "100.71.210.41",
        ])
        let snapshot = resolver.routes(port: 61234, immediateHosts: { [] })
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, _) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
        } else {
            #expect(Bool(false), "Expected callback refresh to populate the numeric route")
        }
    }

    @Test func testMobileHostConnectionCloseOnlyClearsConnectionTracking() {
        let service = MobileHostService.shared
        let connectionID = UUID()
        service.debugResetMobileLifecycleStateForTesting()
        service.debugRecordClientIDForTesting("ios-client", connectionID: connectionID)
        #expect(service.debugTrackedClientIDsForTesting(connectionID: connectionID) == Set(["ios-client"]))
        service.debugRemoveConnectionForTesting(id: connectionID)
        #expect(service.debugTrackedClientIDsForTesting(connectionID: connectionID) == nil)
    }
    @Test func testIdleMobileConnectionDoesNotKeepRequestActivityBusy() {
        MobileHostRequestActivity.resetForTesting()
        MobileHostRequestActivity.beginConnection()
        defer {
            MobileHostRequestActivity.endConnection()
            MobileHostRequestActivity.resetForTesting()
        }
        #expect(!MobileHostRequestActivity.hasActiveRequest)
        #expect(!MobileHostRequestActivity.hasRecentActivity(within: 60))
        #expect(MobileHostRequestActivity.quietDelay(for: 60) == 0)
    }
    @Test func testMobileHostConnectionCloseClearsOnlyClosedClientViewportReports() {
        let service = MobileHostService.shared
        let terminalController = TerminalController.shared
        let connectionID = UUID()
        let surfaceID = UUID()
        service.debugResetMobileLifecycleStateForTesting()
        terminalController.debugResetMobileViewportReportsForTesting()
        terminalController.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "ios-client",
            columns: 54,
            rows: 42
        )
        terminalController.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "ipad-client",
            columns: 84,
            rows: 15
        )
        service.debugRecordClientIDForTesting("ios-client", connectionID: connectionID)
        service.debugRemoveConnectionForTesting(id: connectionID)
        #expect(
            terminalController.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID) == Set(["ipad-client"]),
            "Closing one mobile RPC connection should clear only that connection's viewport reports."
        )
        terminalController.debugResetMobileViewportReportsForTesting()
    }
    @Test func testMobileHostIgnoresStaleListenerStateCallbacks() {
        let service = MobileHostService.shared
        let currentGeneration = UUID()
        let staleGeneration = UUID()
        service.debugResetMobileLifecycleStateForTesting()
        service.debugSetListenerStateForTesting(
            generation: currentGeneration,
            usesEphemeralFallback: true,
            port: 61234
        )
        service.debugHandleListenerStateForTesting(
            .failed(.posix(.ECONNRESET)),
            generation: staleGeneration
        )
        #expect(service.debugListenerGenerationForTesting() == currentGeneration)
        #expect(service.debugListenerUsesEphemeralFallbackForTesting())
        #expect(service.debugListenerPortForTesting() == 61234)
        service.debugHandleListenerStateForTesting(.cancelled, generation: staleGeneration)
        #expect(service.debugListenerGenerationForTesting() == currentGeneration)
        #expect(service.debugListenerUsesEphemeralFallbackForTesting())
        #expect(service.debugListenerPortForTesting() == 61234)
    }
    @Test func testMobileHostWaitingListenerDoesNotPublishRoutes() {
        let service = MobileHostService.shared
        let generation = UUID()
        service.stop()
        service.debugResetMobileLifecycleStateForTesting()
        service.debugSetListenerStateForTesting(
            generation: generation,
            usesEphemeralFallback: false,
            port: 61234
        )
        service.debugHandleListenerStateForTesting(.waiting(.posix(.EADDRINUSE)), generation: generation)
        let status = service.statusSnapshot()
        #expect(!status.isRunning)
        #expect(status.port == nil)
        #expect(status.routes.isEmpty)
        #expect(service.debugListenerPortForTesting() == nil)
    }
    func drainMobileHostMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
private enum MobileHostStartedTestSocketError: Error {
    case listenerPortUnavailable
    case listenerNotReady
    case connectionNotReady
}
final class MobileHostStartedTestSocket: @unchecked Sendable {
    let connection: NWConnection
    private let listener: NWListener
    private let queue: DispatchQueue
    init() throws {
        let queue = DispatchQueue(label: "dev.cmux.mobile-host-started-test-socket")
        let listener = try NWListener(using: .tcp, on: .any)
        let listenerReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                listenerReady.signal()
            }
        }
        listener.newConnectionHandler = { serverConnection in
            serverConnection.start(queue: queue)
        }
        listener.start(queue: queue)
        guard listenerReady.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw MobileHostStartedTestSocketError.listenerNotReady
        }
        guard let port = listener.port else {
            listener.cancel()
            throw MobileHostStartedTestSocketError.listenerPortUnavailable
        }
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        let connectionReady = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connectionReady.signal()
            }
        }
        connection.start(queue: queue)
        guard connectionReady.wait(timeout: .now() + 2) == .success else {
            connection.cancel()
            listener.cancel()
            throw MobileHostStartedTestSocketError.connectionNotReady
        }
        self.listener = listener
        self.connection = connection
        self.queue = queue
    }
    func close() {
        connection.cancel()
        listener.cancel()
    }
}
actor MobileHostConnectionCloseRecorder {
    private var ids: [UUID] = []
    func record(_ id: UUID) {
        ids.append(id)
    }
    func recordedIDs() -> [UUID] {
        ids
    }
}
actor MobileHostAuthorizationInvocationRecorder {
    private var invocations = 0
    func record() { invocations += 1 }
    func count() -> Int { invocations }
}
actor MobileHostConnectionRequestRecorder {
    private var methods: [String] = []
    func record(_ request: MobileHostRPCRequest) {
        methods.append(request.method)
    }
    func recordedMethods() -> [String] {
        methods
    }
}
actor MobileHostConnectionBox {
    private var session: MobileHostConnection?
    func set(_ session: MobileHostConnection) {
        self.session = session
    }
    func close(reason: String) async {
        await session?.close(reason: reason)
    }
}
actor RecordingMobileHostByteTransport: CmxByteTransport {
    private var sent: [Data] = []
    private var closeCount = 0

    func connect() async throws {}
    func receive() async throws -> Data? { nil }
    func send(_ data: Data) async throws { sent.append(data) }
    func close() async { closeCount += 1 }

    func waitForSentBufferCount(_ count: Int) async -> [Data] {
        for _ in 0..<1_000 {
            if sent.count >= count { return sent }
            await Task.yield()
        }
        return sent
    }

    func observedCloseCount() -> Int { closeCount }
}
private enum TestMobileHostIndependentEventWriterError: Error {
    case failed
}
actor TestMobileHostIndependentEventWriter: MobileHostIndependentEventWriting {
    enum Behavior: Sendable {
        case failAfterProbe
        case blockAfterProbe
    }

    private let behavior: Behavior
    private var sendCount = 0
    private var closeCount = 0
    private var blockedWaiter: CheckedContinuation<Void, any Error>?
    private var blockedProbeWaiter: CheckedContinuation<Bool, Never>?
    private let blockedStream: AsyncStream<Void>
    private let blockedContinuation: AsyncStream<Void>.Continuation
    private let blockedProbeStream: AsyncStream<Void>
    private let blockedProbeContinuation: AsyncStream<Void>.Continuation

    init(behavior: Behavior) {
        self.behavior = behavior
        let blocked = AsyncStream<Void>.makeStream()
        blockedStream = blocked.stream
        blockedContinuation = blocked.continuation
        let blockedProbe = AsyncStream<Void>.makeStream()
        blockedProbeStream = blockedProbe.stream
        blockedProbeContinuation = blockedProbe.continuation
    }

    func probe(_: Data) async -> Bool {
        if blockedWaiter != nil {
            blockedProbeContinuation.yield(())
            return await withCheckedContinuation { continuation in
                blockedProbeWaiter = continuation
            }
        }
        sendCount += 1
        return true
    }

    func send(_: Data) async throws {
        sendCount += 1
        switch behavior {
        case .failAfterProbe:
            throw TestMobileHostIndependentEventWriterError.failed
        case .blockAfterProbe:
            blockedContinuation.yield(())
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    blockedWaiter = continuation
                }
            } onCancel: {
                Task { await self.cancelBlockedSend() }
            }
        }
    }

    func reset() async {
        blockedWaiter?.resume(throwing: TestMobileHostIndependentEventWriterError.failed)
        blockedWaiter = nil
    }

    func close() async {
        closeCount += 1
        blockedWaiter?.resume(throwing: CancellationError())
        blockedWaiter = nil
        blockedProbeWaiter?.resume(returning: false)
        blockedProbeWaiter = nil
    }

    func blockedEvents() -> AsyncStream<Void> { blockedStream }
    func blockedProbeEvents() -> AsyncStream<Void> { blockedProbeStream }
    func observedSendCount() -> Int { sendCount }
    func observedCloseCount() -> Int { closeCount }

    func failBlockedSend() {
        blockedWaiter?.resume(throwing: TestMobileHostIndependentEventWriterError.failed)
        blockedWaiter = nil
    }

    func releaseBlockedProbe(result: Bool) {
        blockedProbeWaiter?.resume(returning: result)
        blockedProbeWaiter = nil
    }

    private func cancelBlockedSend() {
        blockedWaiter?.resume(throwing: CancellationError())
        blockedWaiter = nil
    }
}
struct ImmediateMobileHostIrohClock: CmxIrohRelayClock {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { instant }
    func sleep(until _: Date) async throws {}
}
actor BlockingMobileHostIrohSendStream: CmxIrohSendStream {
    private var sendWaiter: CheckedContinuation<Void, any Error>?
    private var resetCodes: [UInt64] = []
    private var wasReset = false

    func send(_: Data) async throws {
        guard !wasReset else {
            throw TestMobileHostIndependentEventWriterError.failed
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sendWaiter = continuation
            }
        } onCancel: {
            Task { await self.cancelSend() }
        }
    }

    func finish() async throws {}

    func reset(errorCode: UInt64) async {
        wasReset = true
        resetCodes.append(errorCode)
        sendWaiter?.resume(throwing: TestMobileHostIndependentEventWriterError.failed)
        sendWaiter = nil
    }

    func setPriority(_: Int32) async throws {}
    func observedResetCodes() -> [UInt64] { resetCodes }

    private func cancelSend() {
        sendWaiter?.resume(throwing: CancellationError())
        sendWaiter = nil
    }
}
actor ImmediateMobileHostIrohReceiveStream: CmxIrohReceiveStream {
    func receive(maximumByteCount _: Int) -> Data? { nil }
    func stop(errorCode _: UInt64) {}
}
private enum AsyncTestSignalError: Error {
    case timedOut
}
final class AsyncTestSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var fulfilled = false
    func fulfill() {
        condition.lock()
        fulfilled = true
        condition.broadcast()
        condition.unlock()
    }
    func wait(timeout: TimeInterval = 1) async throws {
        try await Task.detached { [self] in
            try blockingWait(timeout: timeout)
        }.value
    }
    private func blockingWait(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !fulfilled {
            if !condition.wait(until: deadline) {
                throw AsyncTestSignalError.timedOut
            }
        }
    }
}
final class SendableSemaphore: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    init(value: Int) {
        semaphore = DispatchSemaphore(value: value)
    }
    func wait() {
        semaphore.wait()
    }
    func signal() {
        semaphore.signal()
    }
}
private final class LockedHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []
    func set(_ nextHosts: [String]) {
        lock.lock()
        hosts = nextHosts
        lock.unlock()
    }
    func value() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }
}
