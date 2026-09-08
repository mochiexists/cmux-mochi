import AppKit
import CmuxFoundation
import os

/// Self-heals an orphaned drag session that has latched a mouse button.
///
/// SwiftUI `.onDrag` and `.draggable` sources begin an OS drag session that
/// the app never explicitly ends. If the release is lost, the Dock's drag
/// server keeps the button "held", the drag image sticks to the cursor, and
/// every system trackpad gesture dies until `killall Dock`. The existing
/// sidebar failsafe only resets cmux's own visual state and only watches the
/// left button; it never releases the session.
///
/// The monitor is surface-agnostic but deliberately narrow. It only acts on a
/// button whose press was delivered to this app while the hardware reported
/// it down, whose session state still says "held" while the hardware now says
/// "up", and for which no mouse event of any kind has arrived for a few
/// seconds. See ``DragSessionLatchPolicy`` for
/// why each condition is there. When all hold, it posts a synthetic mouse-up
/// through the session event tap, which is the release the drag server has
/// been waiting for. Posting is skipped, with one log line, when the process
/// lacks post-event authorization; it never prompts for it.
///
/// Opt out with `defaults write com.cmux-mochi cmuxDragSessionLatchFailsafeDisabled -bool YES`.
@MainActor
final class DragSessionLatchMonitor {
    private static let logger = Logger(subsystem: "com.cmux-mochi", category: "DragSessionLatch")
    private static let pollInterval: TimeInterval = 0.5
    private static let recoveryCheckDelay: TimeInterval = 0.5
    private static let disabledDefaultsKey = "cmuxDragSessionLatchFailsafeDisabled"

    private struct WatchedButton {
        let button: CGMouseButton
        let down: NSEvent.EventType
        let up: NSEvent.EventType
        let upEventType: CGEventType
    }

    private static let watchedButtons: [WatchedButton] = [
        WatchedButton(button: .left, down: .leftMouseDown, up: .leftMouseUp, upEventType: .leftMouseUp),
        WatchedButton(button: .right, down: .rightMouseDown, up: .rightMouseUp, upEventType: .rightMouseUp),
    ]

    private static let anyMouseActivity: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    private let policy: DragSessionLatchPolicy
    private var timer: DispatchSourceTimer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var latchedSince: [CGMouseButton: TimeInterval] = [:]
    private var lastReleaseAt: [CGMouseButton: TimeInterval] = [:]
    /// Buttons whose mouse-down this app received and whose mouse-up it has
    /// not yet seen.
    private var pressObservedByApp: Set<CGMouseButton> = []
    private var lastMouseEventAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var didLogMissingPostAccess = false

    init(policy: DragSessionLatchPolicy = DragSessionLatchPolicy()) {
        self.policy = policy
    }

    func start() {
        guard timer == nil else { return }
        // Test hosts drive the mouse synthetically and must not have their
        // buttons released under them.
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_TEST_PROCESS"] == "1" || environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        if UserDefaults.standard.bool(forKey: Self.disabledDefaultsKey) {
            Self.logger.notice("disabled by \(Self.disabledDefaultsKey, privacy: .public)")
            return
        }
        installEventMonitors()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        latchedSince.removeAll()
        lastReleaseAt.removeAll()
        pressObservedByApp.removeAll()
    }

    // MARK: - event observation

    private func installEventMonitors() {
        // Local: events delivered to this app. This is the ownership signal:
        // only a press cmux received can begin a hold cmux is allowed to end.
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.anyMouseActivity) { [weak self] event in
            MainActor.assumeIsolated {
                self?.noteLocalMouseEvent(event)
            }
            return event
        }
        // Global: events delivered to other apps. An activity signal, and an
        // ownership revocation: a press that another app received is that
        // app's gesture, never ours to end.
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.anyMouseActivity) { [weak self] event in
            let type = event.type
            Task { @MainActor [weak self] in
                self?.noteGlobalMouseEvent(type)
            }
        }
    }

    private func noteGlobalMouseEvent(_ type: NSEvent.EventType) {
        noteMouseActivity()
        for watched in Self.watchedButtons where type == watched.down {
            pressObservedByApp.remove(watched.button)
            latchedSince[watched.button] = nil
        }
    }

    private func noteLocalMouseEvent(_ event: NSEvent) {
        noteMouseActivity()
        for watched in Self.watchedButtons {
            if event.type == watched.down {
                // Only a hardware-backed press can begin a hold we may end. A
                // synthetic press from a remote-control or automation tool
                // reads hardware-up at the moment it arrives, so it never
                // arms recovery, and the orphaned-drag signature can no
                // longer be confused with a remote user holding still.
                if CGEventSource.buttonState(.hidSystemState, button: watched.button) {
                    pressObservedByApp.insert(watched.button)
                } else {
                    pressObservedByApp.remove(watched.button)
                }
                // A new press is a new gesture; never carry latch timing across.
                latchedSince[watched.button] = nil
            } else if event.type == watched.up {
                pressObservedByApp.remove(watched.button)
                latchedSince[watched.button] = nil
            }
        }
    }

    private func noteMouseActivity() {
        lastMouseEventAt = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - polling

    private func poll() {
        guard !pressObservedByApp.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for watched in Self.watchedButtons where pressObservedByApp.contains(watched.button) {
            let state = DragSessionLatchPolicy.ButtonState(
                hardwareDown: CGEventSource.buttonState(.hidSystemState, button: watched.button),
                sessionDown: CGEventSource.buttonState(.combinedSessionState, button: watched.button),
                pressObservedByApp: true,
                secondsSinceLastMouseEvent: now - lastMouseEventAt
            )
            // Local monitors miss releases consumed inside tracking loops, so
            // a completed gesture could otherwise keep ownership forever. The
            // session reading "up" is the authoritative end of any hold.
            if !state.sessionDown && !state.hardwareDown {
                pressObservedByApp.remove(watched.button)
                latchedSince[watched.button] = nil
                continue
            }
            switch policy.decide(
                state: state,
                latchedSince: latchedSince[watched.button],
                lastReleaseAt: lastReleaseAt[watched.button],
                now: now
            ) {
            case .idle:
                latchedSince[watched.button] = nil
            case .latching(let since):
                latchedSince[watched.button] = since
            case .release(let latchedFor):
                lastReleaseAt[watched.button] = now
                postSyntheticRelease(watched, latchedFor: latchedFor)
            }
        }
    }

    private func postSyntheticRelease(_ watched: WatchedButton, latchedFor: TimeInterval) {
        guard CGPreflightPostEventAccess() else {
            if !didLogMissingPostAccess {
                didLogMissingPostAccess = true
                Self.logger.warning(
                    "button \(watched.button.rawValue) latched \(latchedFor, format: .fixed(precision: 1))s but this process lacks post-event access; not releasing and not prompting"
                )
            }
            return
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let release = CGEvent(
            mouseEventSource: nil,
            mouseType: watched.upEventType,
            mouseCursorPosition: location,
            mouseButton: watched.button
        ) else {
            Self.logger.error("could not build synthetic release for button \(watched.button.rawValue)")
            return
        }
        // The session tap is where the drag server and every app observe
        // events; a release here ends the orphaned drag session the same way a
        // physical release would.
        release.post(tap: .cgSessionEventTap)
        Self.logger.warning(
            "posted release for latched mouse button \(watched.button.rawValue) after \(latchedFor, format: .fixed(precision: 1))s"
        )
#if DEBUG
        cmuxDebugLog("drag.latch.release button=\(watched.button.rawValue) latchedFor=\(latchedFor)")
#endif
        // Report whether it took: the post returns nothing, so the only proof
        // is the session state clearing shortly afterwards.
        let button = watched.button
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoveryCheckDelay) { [weak self] in
            guard self != nil else { return }
            let stillDown = CGEventSource.buttonState(.combinedSessionState, button: button)
            if stillDown {
                Self.logger.error("session still reports button \(button.rawValue) held after synthetic release")
            } else {
                Self.logger.notice("session released button \(button.rawValue); drag latch cleared")
            }
        }
    }
}
