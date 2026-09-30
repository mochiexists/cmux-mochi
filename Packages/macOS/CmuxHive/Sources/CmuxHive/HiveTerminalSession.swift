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
    /// Identifies one mounted output consumer of the shared remote stream.
    public struct Subscription: Hashable, Sendable {
        fileprivate let id: UUID

        fileprivate init(id: UUID = UUID()) {
            self.id = id
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case attached
    }

    private struct Subscriber {
        let onOutput: @MainActor @Sendable (Data) -> Void
        let onEnd: @MainActor @Sendable () -> Void
    }

    public let surfaceID: String
    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let shell: any HiveTerminalShellServing
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var registrationToken: UUID?
    @ObservationIgnored private var outputGeneration: UUID?
    @ObservationIgnored private var subscribers: [Subscription: Subscriber] = [:]

    public init(surfaceID: String, shell: any HiveTerminalShellServing) {
        self.surfaceID = surfaceID
        self.shell = shell
    }

    /// Adds one output consumer and starts the shared remote stream if needed.
    ///
    /// Every consumer receives the bytes from the same shell registration. Use
    /// ``subscribe(onOutput:onEnd:)`` when the caller must prepare a viewport
    /// before starting the first remote replay.
    ///
    /// - Parameters:
    ///   - onOutput: Receives every output chunk from the shared registration.
    ///   - onEnd: Runs whenever the current registration ends naturally.
    /// - Returns: A token that removes only this consumer.
    @discardableResult
    public func attach(
        onOutput: @escaping @MainActor @Sendable (Data) -> Void,
        onEnd: @escaping @MainActor @Sendable () -> Void = {}
    ) -> Subscription {
        let subscription = subscribe(onOutput: onOutput, onEnd: onEnd)
        startOutput()
        return subscription
    }

    /// Adds one output consumer without starting a remote registration.
    ///
    /// - Parameters:
    ///   - onOutput: Receives every output chunk once ``startOutput()`` runs.
    ///   - onEnd: Runs whenever the current registration ends naturally.
    /// - Returns: A token that removes only this consumer.
    @discardableResult
    public func subscribe(
        onOutput: @escaping @MainActor @Sendable (Data) -> Void,
        onEnd: @escaping @MainActor @Sendable () -> Void = {}
    ) -> Subscription {
        let subscription = Subscription()
        subscribers[subscription] = Subscriber(
            onOutput: onOutput,
            onEnd: onEnd
        )
        return subscription
    }

    /// Starts one shell registration shared by every current subscriber.
    public func startOutput() {
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
                for subscriber in self.subscribers.values {
                    subscriber.onOutput(chunk.data)
                }
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
            for subscriber in self.subscribers.values {
                subscriber.onEnd()
            }
        }
    }

    /// Removes one mounted consumer without disturbing the others.
    ///
    /// The shell registration is unmounted only after its final consumer leaves.
    ///
    /// - Parameter subscription: Token returned by ``attach(onOutput:onEnd:)``
    ///   or ``subscribe(onOutput:onEnd:)``.
    public func detach(_ subscription: Subscription) {
        subscribers.removeValue(forKey: subscription)
        if subscribers.isEmpty {
            stopOutput()
        }
    }

    /// Ends the current stream and removes every mounted consumer.
    public func detach() {
        subscribers.removeAll()
        stopOutput()
    }

    /// Ends the current shell registration while retaining mounted consumers.
    ///
    /// Use this after a transport failure; a later ``startOutput()`` reconnects
    /// the same consumers without creating duplicate subscriptions.
    public func stopOutput() {
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
