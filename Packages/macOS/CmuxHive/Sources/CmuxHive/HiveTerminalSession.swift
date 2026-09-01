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

    public init(surfaceID: String, shell: any HiveTerminalShellServing) {
        self.surfaceID = surfaceID
        self.shell = shell
    }

    /// Start one output generation. Repeated calls while attached are ignored.
    public func attach(
        onOutput: @escaping @MainActor @Sendable (Data) -> Void
    ) {
        guard outputTask == nil else { return }
        let registration = shell.terminalOutputRegistration(surfaceID: surfaceID)
        registrationToken = registration.registrationToken
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
        }
    }

    /// End this exact mounted output generation without closing the remote PTY.
    public func detach() {
        outputTask?.cancel()
        outputTask = nil
        if let registrationToken {
            shell.terminalOutputDidUnmount(
                surfaceID: surfaceID,
                registrationToken: registrationToken
            )
        }
        registrationToken = nil
        phase = .idle
    }

    /// Send already-encoded terminal input to this remote surface.
    public func send(_ data: Data) {
        shell.sendTerminalRawInput(data, surfaceID: surfaceID)
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
