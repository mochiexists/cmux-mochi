/// Where a new surface starts and what it types first, once the requested
/// working directory has been checked by ``TerminalWorkingDirectoryAccessGate``.
///
/// When the directory's open stalls, the surface starts in the home folder
/// instead, so `ghostty_surface_new` never opens a protected path on the main
/// thread. If the surface runs an interactive shell, `cd '<dir>'` is typed
/// ahead of any other startup input; the shell then waits for macOS in its own
/// process and lands in the right folder once access is answered.
public struct TerminalWorkingDirectoryLaunchPlan: Sendable, Equatable {
    /// The directory passed to Ghostty.
    public let workingDirectory: String?

    /// The startup input passed to Ghostty.
    public let initialInput: String?

    /// The requested directory when the plan fell back to home; `nil` when
    /// the surface starts where it was asked to.
    public let deferredWorkingDirectory: String?

    /// Resolves the plan for one surface.
    ///
    /// - Parameters:
    ///   - requestedWorkingDirectory: The directory the surface asked for.
    ///   - initialInput: Startup input already planned for the surface.
    ///   - inputReachesShell: Whether startup input is read by an interactive
    ///     shell (cmux's managed shell or the user's shell) rather than an
    ///     explicit command, which must not receive a typed `cd`.
    ///   - gate: The shared access gate.
    /// - Returns: The plan; consults the gate only for a non-home directory.
    public static func resolve(
        requestedWorkingDirectory: String?,
        initialInput: String?,
        inputReachesShell: Bool,
        gate: TerminalWorkingDirectoryAccessGate
    ) -> Self {
        guard let requested = requestedWorkingDirectory,
              !requested.isEmpty,
              requested != gate.homeDirectory,
              gate.check(requested) == .timedOut else {
            return Self(
                workingDirectory: requestedWorkingDirectory,
                initialInput: initialInput,
                deferredWorkingDirectory: nil
            )
        }
        guard inputReachesShell else {
            return Self(
                workingDirectory: gate.homeDirectory,
                initialInput: initialInput,
                deferredWorkingDirectory: requested
            )
        }
        let changeDirectory = "cd \(TerminalSurface.shellSingleQuoted(requested))"
        // Chain planned input (an agent resume, say) on the cd so it never runs
        // in the home folder when the cd fails.
        let plannedInput: String
        if let initialInput, !initialInput.isEmpty {
            plannedInput = "\(changeDirectory) && \(initialInput)"
        } else {
            plannedInput = "\(changeDirectory)\n"
        }
        return Self(
            workingDirectory: gate.homeDirectory,
            initialInput: plannedInput,
            deferredWorkingDirectory: requested
        )
    }
}
