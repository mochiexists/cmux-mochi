#if os(iOS)
import Foundation
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite("Computer removal affordance")
struct ComputerRemovalAffordanceTests {
    @Test("visible and disconnected rows expose the shared removal affordance")
    func bothRowPresentationsExposeRemoval() {
        let snapshot = makeSnapshot()
        let visible = MacComputerRow(
            computer: snapshot,
            remove: { _ in },
            style: .computers
        )
        let disconnected = MacComputerRow(
            computer: snapshot,
            remove: { _ in },
            style: .reconnect
        )

        #expect(visible.removalAffordanceAvailable)
        #expect(disconnected.removalAffordanceAvailable)
    }

    @Test("confirmation must be requested before destructive work can begin")
    func confirmationGatesMutation() {
        var state = ComputerRemovalConfirmationState()

        let unrequestedRemoval = state.beginConfirmedRemoval(affordanceAvailable: true)
        #expect(!unrequestedRemoval)
        state.request(affordanceAvailable: true)
        #expect(state.isPresented)
        let confirmedRemoval = state.beginConfirmedRemoval(affordanceAvailable: true)
        #expect(confirmedRemoval)
        #expect(!state.isPresented)
        let repeatedRemoval = state.beginConfirmedRemoval(affordanceAvailable: true)
        #expect(!repeatedRemoval)
    }

    @Test("rows without a removal action cannot present destructive confirmation")
    func unavailableActionCannotConfirm() {
        var state = ComputerRemovalConfirmationState()

        state.request(affordanceAvailable: false)

        #expect(!state.isPresented)
        let unavailableRemoval = state.beginConfirmedRemoval(affordanceAvailable: false)
        #expect(!unavailableRemoval)
    }

    @Test("a confirmed removal outlives the row that launched it")
    func removalOutlivesRowPresentation() async {
        let completion = RemovalCompletionProbe()
        var transaction: ComputerRemovalTransaction? = ComputerRemovalTransaction()

        let started = transaction?.begin {
            await completion.finish()
        }
        transaction = nil

        #expect(started == true)
        await completion.wait()
        #expect(await completion.didFinish)
    }

    private func makeSnapshot() -> MacComputerSnapshot {
        MacComputerSnapshot(
            deviceId: "mac-a",
            instanceTag: "nightly",
            title: "Desk Mac",
            platform: "macOS",
            colorIndex: nil,
            customColor: nil,
            customIcon: nil,
            connectionStatus: .unavailable,
            presence: .offline(lastSeenAt: Date(timeIntervalSince1970: 1)),
            buildLabel: "Nightly",
            routeDescription: nil,
            lastSeenAt: Date(timeIntervalSince1970: 1),
            workspaceCount: 0,
            aliasIDs: ["mac-a"]
        )
    }
}

private actor RemovalCompletionProbe {
    private(set) var didFinish = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        didFinish = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
    }

    func wait() async {
        guard !didFinish else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
#endif
