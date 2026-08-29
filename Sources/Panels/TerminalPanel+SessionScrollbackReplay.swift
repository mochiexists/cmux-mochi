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
    func markSessionScrollbackExplicitlyCleared() {
        let marker = SessionScrollbackReplayStore.makeContinuationBoundaryMarker()
        sessionScrollbackReplayBaseline = nil
        sessionScrollbackReplayBoundaryMarker = marker
        sessionScrollbackFallbackInvalidatedByClear = true
        surface.installHistoryClearCaptureBoundary(marker)
    }

    /// Accepts only a capture that is known to be on the correct side of an
    /// explicit clear. A capture containing the concealed boundary raced the
    /// asynchronous clear and must not replace the durable fallback.
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

        if sessionScrollbackFallbackInvalidatedByClear, containsBoundary {
            return false
        }
        if !containsBoundary {
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
