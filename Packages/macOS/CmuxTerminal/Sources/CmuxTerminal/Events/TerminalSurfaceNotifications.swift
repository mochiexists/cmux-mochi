public import Foundation

public extension Notification.Name {
    /// Posted by ``TerminalSurface`` after a runtime surface finishes
    /// creation (`userInfo`: `surfaceId`, `workspaceId`; `object`: the
    /// surface model).
    static let terminalSurfaceDidBecomeReady =
        Notification.Name("cmux.terminalSurfaceDidBecomeReady")

    /// Posted by ``TerminalSurface`` when its working directory did not open
    /// within ``TerminalWorkingDirectoryAccessGate/deadline`` and the surface
    /// started in the home folder instead (`userInfo`: `surfaceId`,
    /// `workspaceId`, `workingDirectory`; `object`: the surface model).
    /// Posted before ``terminalSurfaceDidBecomeReady``.
    static let terminalSurfaceWorkingDirectoryAccessDeferred =
        Notification.Name("cmux.terminalSurfaceWorkingDirectoryAccessDeferred")

    /// Posted by ``TerminalSurface`` after a runtime clipboard read
    /// completes (`object`: the surface model).
    static let terminalSurfaceDidCompleteClipboardRead =
        Notification.Name("terminalSurfaceDidCompleteClipboardRead")
}
