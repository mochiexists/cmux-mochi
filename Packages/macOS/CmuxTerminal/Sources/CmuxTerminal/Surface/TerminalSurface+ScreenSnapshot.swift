extension TerminalSurface {
    /// Reads a byte-bounded VT reconstruction of the newest physical terminal rows.
    ///
    /// Ghostty selects the history suffix and formats it into a fixed-size buffer
    /// before any bytes cross into Swift. The result therefore preserves rendered
    /// styles, conceal, wide characters, and graphemes without exposing raw PTY
    /// output or requiring a render-grid JSON snapshot.
    ///
    /// - Parameters:
    ///   - maxRows: Maximum number of physical history/current-screen rows to include.
    ///   - maxBytes: Hard maximum for the formatted VT byte buffer.
    /// - Returns: A complete UTF-8 VT reconstruction, or `nil` when no bounded snapshot is available.
    @MainActor
    public func boundedScreenTailVT(maxRows: Int, maxBytes: Int) async -> String? {
        guard maxRows > 0,
              maxBytes > 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "boundedScreenTailVT") else {
            return nil
        }
        return await runtimeTeardown.readScreenTailVT(
            TerminalSurfaceRuntimeScreenTailRequest(
                surface: surface,
                maxRows: maxRows,
                maxBytes: maxBytes
            )
        )
    }

    /// Reads the same bounded VT reconstruction synchronously on the main actor.
    ///
    /// Session autosave walks every terminal panel in one synchronous main-actor
    /// pass and cannot suspend per surface, so it needs a non-async read. The
    /// call is safe without the teardown coordinator: ``liveSurfaceForGhosttyAccess(reason:)``
    /// only vends a pointer that main-thread owner state still holds, and a
    /// native free is enqueued only after that state has released it, so the
    /// read and the free cannot overlap. Ghostty takes the renderer mutex for
    /// the duration of the read; nothing here touches the filesystem.
    ///
    /// - Parameters:
    ///   - maxRows: Maximum number of physical history/current-screen rows to include.
    ///   - maxBytes: Hard maximum for the formatted VT byte buffer.
    /// - Returns: A complete UTF-8 VT reconstruction, or `nil` when no bounded snapshot is available.
    @MainActor
    public func boundedScreenTailVTNow(maxRows: Int, maxBytes: Int) -> String? {
        guard maxRows > 0,
              maxBytes > 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "boundedScreenTailVTNow") else {
            return nil
        }
        return TerminalSurfaceRuntimeScreenTailRequest(
            surface: surface,
            maxRows: maxRows,
            maxBytes: maxBytes
        ).read()
    }
}
