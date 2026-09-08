import Testing
@testable import CmuxFoundation

@Suite struct DragSessionLatchPolicyTests {
    private typealias ButtonState = DragSessionLatchPolicy.ButtonState

    /// The canonical orphaned drag: cmux received the press, hardware is up,
    /// session still down, and nothing has moved for a while.
    private func orphaned(quietFor: Double = 10) -> ButtonState {
        ButtonState(hardwareDown: false, sessionDown: true, pressObservedByApp: true, secondsSinceLastMouseEvent: quietFor)
    }

    @Test func agreementIsNeverLatched() {
        let policy = DragSessionLatchPolicy()
        #expect(!policy.isLatched(ButtonState(hardwareDown: false, sessionDown: false, pressObservedByApp: true, secondsSinceLastMouseEvent: 99)))
        #expect(!policy.isLatched(ButtonState(hardwareDown: true, sessionDown: true, pressObservedByApp: true, secondsSinceLastMouseEvent: 99)))
    }

    @Test func physicallyHeldButtonIsLeftAlone() {
        // A stuck trackpad contact reports hardware down; that is not ours to fix.
        let policy = DragSessionLatchPolicy()
        let held = ButtonState(hardwareDown: true, sessionDown: false, pressObservedByApp: true, secondsSinceLastMouseEvent: 99)
        #expect(policy.decide(state: held, latchedSince: 0, lastReleaseAt: nil, now: 100) == .idle)
    }

    @Test func pressNotDeliveredToAppIsNeverACandidate() {
        // A remote-control tool holding a synthetic button over another app
        // shows the same hardware-up/session-down signature. Not ours.
        let policy = DragSessionLatchPolicy()
        let elsewhere = ButtonState(hardwareDown: false, sessionDown: true, pressObservedByApp: false, secondsSinceLastMouseEvent: 99)
        #expect(policy.isLatched(elsewhere))
        #expect(!policy.isCandidate(elsewhere))
        #expect(policy.decide(state: elsewhere, latchedSince: 0, lastReleaseAt: nil, now: 100) == .idle)
    }

    @Test func liveInputKeepsALatchFromReleasing() {
        // A synthetic drag aimed at cmux that is still alive keeps delivering
        // drag events; the quiet requirement is what protects it.
        let policy = DragSessionLatchPolicy(releaseAfter: 2, quietAfter: 3, cooldown: 5)
        let moving = orphaned(quietFor: 0.4)
        #expect(policy.decide(state: moving, latchedSince: 10, lastReleaseAt: nil, now: 20) == .latching(since: 10))
    }

    @Test func latchStartsTimingOnFirstDisagreement() {
        let policy = DragSessionLatchPolicy(releaseAfter: 2, quietAfter: 3, cooldown: 5)
        #expect(policy.decide(state: orphaned(), latchedSince: nil, lastReleaseAt: nil, now: 10) == .latching(since: 10))
        #expect(policy.decide(state: orphaned(), latchedSince: 10, lastReleaseAt: nil, now: 11.9) == .latching(since: 10))
    }

    @Test func releasesOnceLatchedAndQuietLongEnough() {
        let policy = DragSessionLatchPolicy(releaseAfter: 2, quietAfter: 3, cooldown: 5)
        #expect(policy.decide(state: orphaned(quietFor: 2.9), latchedSince: 10, lastReleaseAt: nil, now: 12) == .latching(since: 10))
        #expect(policy.decide(state: orphaned(quietFor: 3), latchedSince: 10, lastReleaseAt: nil, now: 12) == .release(latchedFor: 2))
        #expect(policy.decide(state: orphaned(), latchedSince: 10, lastReleaseAt: nil, now: 15) == .release(latchedFor: 5))
    }

    @Test func cooldownBlocksRepeatedReleases() {
        let policy = DragSessionLatchPolicy(releaseAfter: 2, quietAfter: 3, cooldown: 5)
        #expect(policy.decide(state: orphaned(), latchedSince: 10, lastReleaseAt: 12, now: 14) == .latching(since: 10))
        #expect(policy.decide(state: orphaned(), latchedSince: 10, lastReleaseAt: 12, now: 17) == .release(latchedFor: 7))
    }

    @Test func recoveryResetsToIdle() {
        let policy = DragSessionLatchPolicy()
        let released = ButtonState(hardwareDown: false, sessionDown: false, pressObservedByApp: false, secondsSinceLastMouseEvent: 0)
        #expect(policy.decide(state: released, latchedSince: 10, lastReleaseAt: 12, now: 30) == .idle)
    }
}
