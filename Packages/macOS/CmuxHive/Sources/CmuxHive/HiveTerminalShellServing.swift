public import CmuxMobileShell
public import Foundation

/// Exact terminal-stream capabilities Hive delegates to the shared shell.
@MainActor
public protocol HiveTerminalShellServing: AnyObject {
    func terminalOutputRegistration(
        surfaceID: String
    ) -> MobileTerminalOutputRegistration

    func terminalOutputDidProcess(surfaceID: String, streamToken: UUID)

    func terminalOutputDidUnmount(surfaceID: String, registrationToken: UUID)

    func sendTerminalRawInput(_ data: Data, surfaceID: String)

    func prepareTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) -> MobileTerminalViewportPreparation?

    func updatePreparedTerminalViewport(
        _ preparation: MobileTerminalViewportPreparation
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )?

    func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )?
}

extension MobileShellComposite: HiveTerminalShellServing {}
