public import Foundation

/// Decides when an orphaned drag session has latched a mouse button.
///
/// macOS drag-and-drop is brokered by the Dock's drag server. When a drag
/// session loses its release (a SwiftUI `.onDrag` / `.draggable` source has no
/// app-owned end, and a dropped trackpad release never reaches it), the event
/// session keeps reporting the button as held while the hardware already
/// reports it up. In that state system gestures (Mission Control, Spaces,
/// swipes) stay dead until the Dock restarts.
///
/// Hardware-up while session-down is necessary but not sufficient: remote
/// control and automation tools legitimately post synthetic presses into the
/// session with no hardware behind them. So a release is only considered when
/// ALL of these hold for the same button:
/// - the app itself received the press that started the hold, and the
///   hardware reported the button down at that moment, so this is a physical
///   gesture aimed at cmux and not a synthetic press from another tool;
/// - the session still reports the button held while the hardware does not;
/// - no mouse event of any kind has reached the app for ``quietAfter``; a live
///   drag, even a synthetic one, keeps producing drag events, an orphaned
///   session produces none;
/// - the disagreement has lasted ``releaseAfter``.
///
/// A physically held button is never touched.
public struct DragSessionLatchPolicy: Sendable {
    /// One mouse button's state as seen by the two event sources and the app.
    public struct ButtonState: Equatable, Sendable {
        /// `CGEventSource.buttonState(.hidSystemState, …)`: what the hardware says.
        public var hardwareDown: Bool
        /// `CGEventSource.buttonState(.combinedSessionState, …)`: what the
        /// event session, including an active drag, says.
        public var sessionDown: Bool
        /// The app received the mouse-down that began the current hold, the
        /// hardware reported the button down at that moment, and the app has
        /// not yet received the matching mouse-up.
        public var pressObservedByApp: Bool
        /// Seconds since the app last saw any mouse event (down, up, moved,
        /// dragged), from local or global monitors.
        public var secondsSinceLastMouseEvent: TimeInterval

        public init(
            hardwareDown: Bool,
            sessionDown: Bool,
            pressObservedByApp: Bool,
            secondsSinceLastMouseEvent: TimeInterval
        ) {
            self.hardwareDown = hardwareDown
            self.sessionDown = sessionDown
            self.pressObservedByApp = pressObservedByApp
            self.secondsSinceLastMouseEvent = secondsSinceLastMouseEvent
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Not a candidate: hardware and session agree, the button is genuinely
        /// held, or the press was never delivered to this app.
        case idle
        /// A candidate, but not yet long enough or not yet quiet enough to act.
        case latching(since: TimeInterval)
        /// Disagreement has persisted and input has gone quiet; post a release.
        case release(latchedFor: TimeInterval)
    }

    /// How long the disagreement must persist before a release is posted.
    public static let releaseAfter: TimeInterval = 2

    /// How long the app must have seen no mouse event at all. A drag that is
    /// still alive keeps delivering drag events; eight seconds also outlasts
    /// any pause a user is likely to hold over a drop target.
    public static let quietAfter: TimeInterval = 8

    /// Minimum spacing between synthetic releases for the same button, so a
    /// release that does not take effect cannot turn into an event storm.
    public static let cooldown: TimeInterval = 5

    public let releaseAfter: TimeInterval
    public let quietAfter: TimeInterval
    public let cooldown: TimeInterval

    public init(
        releaseAfter: TimeInterval = DragSessionLatchPolicy.releaseAfter,
        quietAfter: TimeInterval = DragSessionLatchPolicy.quietAfter,
        cooldown: TimeInterval = DragSessionLatchPolicy.cooldown
    ) {
        self.releaseAfter = releaseAfter
        self.quietAfter = quietAfter
        self.cooldown = cooldown
    }

    /// The raw source disagreement, before any ownership or quiet checks.
    public func isLatched(_ state: ButtonState) -> Bool {
        state.sessionDown && !state.hardwareDown
    }

    /// A latch that this app is entitled to act on.
    public func isCandidate(_ state: ButtonState) -> Bool {
        isLatched(state) && state.pressObservedByApp
    }

    /// - Parameters:
    ///   - state: the button's current readings.
    ///   - latchedSince: when the current candidate disagreement began, if ongoing.
    ///   - lastReleaseAt: when a synthetic release was last posted for this button.
    ///   - now: the current clock reading.
    public func decide(
        state: ButtonState,
        latchedSince: TimeInterval?,
        lastReleaseAt: TimeInterval?,
        now: TimeInterval
    ) -> Decision {
        guard isCandidate(state) else { return .idle }
        let since = latchedSince ?? now
        let latchedFor = now - since
        guard latchedFor >= releaseAfter,
              state.secondsSinceLastMouseEvent >= quietAfter
        else { return .latching(since: since) }
        if let lastReleaseAt, now - lastReleaseAt < cooldown {
            return .latching(since: since)
        }
        return .release(latchedFor: latchedFor)
    }
}
