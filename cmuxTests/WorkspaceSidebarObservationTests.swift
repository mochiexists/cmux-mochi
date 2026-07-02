import Combine
import Foundation
import XCTest

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceSidebarObservationTests: XCTestCase {
    func testSidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    func testSidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    func testPrivacyBlurredChangeUsesImmediateObservationPublisher() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.isPrivacyBlurred = true

        XCTAssertEqual(
            publishCount,
            1,
            "Privacy blur changes should refresh stable row affordances immediately."
        )
    }

    func testPrivacyBlurredChangeDoesNotUseHeavySidebarObservationPublisher() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.isPrivacyBlurred = true

        XCTAssertEqual(
            publishCount,
            0,
            "Privacy blur changes should not schedule the heavier telemetry/detail row refresh path."
        )
    }

    func testSidebarImmediateObservationPublisherDeliversFirstChangeSynchronously() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.title = "User Edit"

        XCTAssertEqual(
            publishCount,
            1,
            "The first immediate-field change after subscribing must reach the sidebar in the same run-loop turn; coalescing may only defer the tail of a burst."
        )
    }

    func testSidebarImmediateObservationPublisherCoalescesTitleBursts() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        for turn in 0..<20 {
            workspace.title = "Agent Turn \(turn)"
        }

        XCTAssertEqual(
            publishCount,
            1,
            "A synchronous burst of distinct titles must deliver only its leading edge immediately."
        )

        // Generous pump so the 50ms trailing emission fires deterministically.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(
            publishCount,
            2,
            "A coalesced burst must settle with exactly one trailing emission carrying the latest state."
        )
    }

    func testCoalesceLatestKeepsLeadingEdgeSynchronousAndEmitsLatestTrailing() {
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        // First value models the @Published current-state replay: forwarded
        // synchronously without opening a coalesce window.
        subject.send(1)
        XCTAssertEqual(received, [1])

        // First change is the synchronous leading edge and opens the window.
        subject.send(2)
        XCTAssertEqual(received, [1, 2])

        // Burst inside the window coalesces to the latest value.
        subject.send(3)
        subject.send(4)
        subject.send(5)
        XCTAssertEqual(received, [1, 2])

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(received, [1, 2, 5])

        // After the window closes and the trailing window expires, the next
        // value is synchronous again.
        subject.send(6)
        XCTAssertEqual(received, [1, 2, 5, 6])
    }

    func testCoalesceLatestDropsStalePendingValueWhenLeadingSupersedesOverdueTrailing() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        subject.send(1) // replay: forwarded, no window
        subject.send(2) // leading edge: opens window
        subject.send(3) // pending trailing value for the open window
        XCTAssertEqual(received, [1, 2])
        XCTAssertEqual(scheduler.scheduledActionCount, 1)

        // The deadline passes WITHOUT the scheduled callback running,
        // modeling a stalled main run loop with an overdue timer.
        scheduler.advance(by: 0.12)
        subject.send(4) // deadline passed: new leading edge must supersede 3

        XCTAssertEqual(
            received,
            [1, 2, 4],
            "A newer leading value after an overdue deadline must drop the stale pending value."
        )

        scheduler.runScheduledActions()
        XCTAssertEqual(
            received,
            [1, 2, 4],
            "The overdue trailing callback must not emit the superseded stale value out of order."
        )
    }

    func testSidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        XCTAssertEqual(
            publishCount,
            0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }
}

// Deterministic Combine scheduler for coalesceLatest tests: `now` only moves
// via advance(by:), and scheduled actions run only when runScheduledActions()
// is called, so overdue-timer interleavings are exact instead of wall-clock.
private final class VirtualCoalesceScheduler: Scheduler {
    typealias SchedulerTimeType = RunLoop.SchedulerTimeType
    typealias SchedulerOptions = Never

    private(set) var now = SchedulerTimeType(Date(timeIntervalSinceReferenceDate: 0))
    var minimumTolerance: SchedulerTimeType.Stride { .seconds(0) }
    private var scheduledActions: [() -> Void] = []

    var scheduledActionCount: Int { scheduledActions.count }

    func advance(by seconds: TimeInterval) {
        now = SchedulerTimeType(now.date.addingTimeInterval(seconds))
    }

    func runScheduledActions() {
        let actions = scheduledActions
        scheduledActions = []
        actions.forEach { $0() }
    }

    func schedule(options: Never?, _ action: @escaping () -> Void) {
        action()
    }

    func schedule(
        after date: SchedulerTimeType,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) {
        scheduledActions.append(action)
    }

    func schedule(
        after date: SchedulerTimeType,
        interval: SchedulerTimeType.Stride,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) -> Cancellable {
        scheduledActions.append(action)
        return AnyCancellable {}
    }
}
