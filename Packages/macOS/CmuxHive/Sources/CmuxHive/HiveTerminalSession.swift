public import CmuxMobileShell
public import Foundation
public import Observation

/// One remote terminal mounted into a macOS manual-I/O surface.
///
/// The shared shell owns replay, sequence-gap repair, and reconnect. This thin
/// adapter preserves its per-chunk acknowledgement contract and exact output
/// registration lifetime for the Mac renderer.
@MainActor
@Observable
public final class HiveTerminalSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case attached
    }

    public let surfaceID: String
    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let shell: any HiveTerminalShellServing
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var registrationToken: UUID?
    @ObservationIgnored private var outputGeneration: UUID?

    public init(surfaceID: String, shell: any HiveTerminalShellServing) {
        self.surfaceID = surfaceID
        self.shell = shell
    }

    /// Start one output generation. Repeated calls while attached are ignored.
    public func attach(
        onOutput: @escaping @MainActor @Sendable (Data) -> Void,
        onEnd: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        guard outputTask == nil else { return }
        let registration = shell.terminalOutputRegistration(surfaceID: surfaceID)
        let generation = UUID()
        registrationToken = registration.registrationToken
        outputGeneration = generation
        phase = .attached
        outputTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in registration.stream {
                guard !Task.isCancelled else { break }
                onOutput(chunk.data)
                self.shell.terminalOutputDidProcess(
                    surfaceID: self.surfaceID,
                    streamToken: chunk.streamToken
                )
            }
            guard self.outputGeneration == generation else { return }
            self.outputTask = nil
            self.registrationToken = nil
            self.outputGeneration = nil
            self.phase = .idle
            onEnd()
        }
    }

    /// End this exact mounted output generation without closing the remote PTY.
    public func detach() {
        outputTask?.cancel()
        outputTask = nil
        outputGeneration = nil
        if let registrationToken {
            shell.terminalOutputDidUnmount(
                surfaceID: surfaceID,
                registrationToken: registrationToken
            )
        }
        registrationToken = nil
        phase = .idle
    }

    /// Commit the natural viewport before registering output, so the first
    /// cold replay is captured at the local renderer's current dimensions.
    public func prepareViewport(
        columns: Int,
        rows: Int
    ) -> MobileTerminalViewportPreparation? {
        shell.prepareTerminalViewport(
            surfaceID: surfaceID,
            columns: columns,
            rows: rows
        )
    }

    /// Send a viewport generation that was committed before output attach.
    public func updatePreparedViewport(
        _ preparation: MobileTerminalViewportPreparation
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )? {
        await shell.updatePreparedTerminalViewport(preparation)
    }

    /// Send already-encoded terminal input to this remote surface.
    public func send(_ data: Data) {
        shell.sendTerminalRawInput(data, surfaceID: surfaceID)
    }

    /// Replaces the local screen after a renderer grid grows.
    public func refreshVisibleScreen() {
        shell.requestTerminalVisibleScreenReplay(surfaceID: surfaceID)
    }

    /// Report the local renderer's natural grid to the remote host.
    @discardableResult
    public func resize(columns: Int, rows: Int) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )? {
        await shell.updateTerminalViewport(
            surfaceID: surfaceID,
            columns: columns,
            rows: rows
        )
    }
}
