import Foundation

extension TerminalPanel {
    func adoptSessionScrollbackReplayContinuation(
        baseline: String?,
        boundaryMarker: String?
    ) {
        sessionScrollbackReplayBaseline = baseline
        sessionScrollbackReplayBoundaryMarker = boundaryMarker
        sessionScrollbackFallbackInvalidatedByClear = false
    }

    func clearSessionScrollbackReplayContinuation() {
        sessionScrollbackReplayBaseline = nil
        sessionScrollbackReplayBoundaryMarker = nil
    }

    /// Prevents a pre-clear persisted fallback from being reused while Ghostty
    /// completes its asynchronous clear and produces a fresh authoritative capture.
    /// Install the boundary before the action so Ghostty's `clear_screen` retains
    /// it with the current viewport while erasing older history. Captures after
    /// the clear can then prove which rows survived the explicit clear.
    func markSessionScrollbackExplicitlyCleared() {
        let marker = SessionScrollbackReplayStore.makeContinuationBoundaryMarker()
        sessionScrollbackReplayBaseline = nil
        sessionScrollbackReplayBoundaryMarker = marker
        sessionScrollbackFallbackInvalidatedByClear = true
        surface.installHistoryClearCaptureBoundary(marker)
    }

    /// Reinstalls the same concealed boundary after Ghostty consumes the clear.
    /// The pre-clear copy rejects stale captures; this post-clear copy guarantees
    /// a surviving authority marker even when `clear_screen` removes the viewport
    /// row that held the first copy.
    func reinforceSessionScrollbackClearBoundary() {
        guard sessionScrollbackFallbackInvalidatedByClear,
              let marker = sessionScrollbackReplayBoundaryMarker else { return }
        surface.installHistoryClearCaptureBoundary(marker)
    }

    /// Accepts only a capture that is known to be on the correct side of an
    /// explicit clear. Captures before the concealed boundary are rejected;
    /// once it appears, the capture is authoritative and snapshot policy strips
    /// the internal boundary before persistence.
    func acceptSessionScrollbackCapture(_ capturedScrollback: String) -> Bool {
        let containsBoundary: Bool
        if let marker = sessionScrollbackReplayBoundaryMarker {
            containsBoundary = capturedScrollback.contains(marker)
                || capturedScrollback
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .contains(marker)
        } else {
            containsBoundary = false
        }

        if sessionScrollbackFallbackInvalidatedByClear {
            guard containsBoundary else { return false }
            sessionScrollbackFallbackInvalidatedByClear = false
            return true
        }
        // A restored-scrollback boundary can be retired once Ghostty evicts it:
        // its baseline has already been joined into the durable snapshot. An
        // explicit-clear boundary has no baseline, however, and Ghostty exports
        // can transiently omit it before showing it again. Keep that marker for
        // this terminal's lifetime so every later capture can sanitize it.
        if !containsBoundary, sessionScrollbackReplayBaseline != nil {
            clearSessionScrollbackReplayContinuation()
        }
        sessionScrollbackFallbackInvalidatedByClear = false
        return true
    }

    func adoptOwnedSessionScrollbackReplayArtifact(_ fileURL: URL?) {
        ownedSessionScrollbackReplayFileURL = fileURL
    }

    /// Removes only the replay artifact created for this runtime by session restoration.
    func removeOwnedSessionScrollbackReplayArtifact() {
        guard let fileURL = ownedSessionScrollbackReplayFileURL else { return }
        ownedSessionScrollbackReplayFileURL = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
