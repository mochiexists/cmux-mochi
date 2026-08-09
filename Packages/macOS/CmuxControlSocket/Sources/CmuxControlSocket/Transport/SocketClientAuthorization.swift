public import Darwin
public import CmuxSettings

/// Authorizes peer processes for control socket requests.
public struct SocketClientAuthorization {
    /// Creates an authorization helper with no retained process state.
    public init() {}

    /// The authorized command plus any authentication already established by
    /// the transport envelope.
    public struct Result: Sendable {
        /// The control-socket command after removing an accepted capability envelope.
        public let command: String

        /// Whether a verified, telemetry-scoped capability replaces password login.
        public let bypassesPasswordAuthentication: Bool
    }

    /// Returns whether a peer process is allowed to use cmux-only socket operations.
    ///
    /// A non-nil `peerProcessID` must resolve as a descendant of the trusted cmux
    /// process tree. A nil PID fails closed because the caller cannot be tied to
    /// a concrete process. `peerHasSameUID` is supplied by the socket handshake
    /// for callers that need it, but this check intentionally relies on ancestry.
    ///
    /// - Parameters:
    ///   - peerProcessID: The PID reported by the accepted socket, or nil when
    ///     the platform cannot provide one.
    ///   - peerHasSameUID: Whether the peer process has the same user ID as cmux.
    ///   - isDescendant: Predicate that verifies the PID belongs to the trusted
    ///     cmux process tree.
    public func isCmuxOnlyClientAllowed(
        peerProcessID: pid_t?,
        peerHasSameUID _: Bool,
        isDescendant: (pid_t) -> Bool
    ) -> Bool {
        if let peerProcessID {
            return isDescendant(peerProcessID)
        }
        return false
    }

    /// Returns the command carried by an authorized cmux-only request.
    ///
    /// Descendants retain the existing process-tree authorization. The
    /// capability parameters form the runtime seam for terminals whose
    /// process trees are later reparented by a multiplexer.
    ///
    /// - Parameters:
    ///   - command: The raw command line received from the client.
    ///   - peerProcessID: The PID reported by the accepted socket.
    ///   - peerHasSameUID: Whether the peer runs as the same user as cmux.
    ///   - capabilityAuthority: The authority that verifies inherited tokens.
    ///   - isDescendant: Predicate that verifies current process ancestry.
    /// - Returns: The unwrapped command when authorized, otherwise `nil`.
    public func authorizedCommand(
        _ command: String,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        capabilityAuthority: SocketClientCapabilityAuthority,
        isDescendant: (pid_t) -> Bool
    ) -> String? {
        let envelope = SocketClientCapabilityCommand(command)
        if let peerProcessID, isDescendant(peerProcessID) {
            return envelope?.command ?? command
        }
        guard peerHasSameUID,
              let envelope,
              capabilityAuthority.verifies(envelope.capability) else {
            return nil
        }
        return envelope.command
    }

    /// Applies the current socket access mode to a received command.
    ///
    /// Owner-only modes verify the peer UID for every command instead of
    /// relying solely on socket-file permissions. This keeps restrictive
    /// modes fail-closed if a permission change cannot be applied to the
    /// filesystem entry of an already running listener.
    public func authorizedCommand(
        _ command: String,
        accessMode: SocketControlMode,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        capabilityAuthority: SocketClientCapabilityAuthority,
        isDescendant: (pid_t) -> Bool
    ) -> String? {
        authorizationResult(
            command,
            accessMode: accessMode,
            peerProcessID: peerProcessID,
            peerHasSameUID: peerHasSameUID,
            capabilityAuthority: capabilityAuthority,
            isDescendant: isDescendant
        )?.command
    }

    /// Applies the current socket access mode and preserves whether a verified
    /// terminal capability has already authenticated password-mode telemetry.
    public func authorizationResult(
        _ command: String,
        accessMode: SocketControlMode,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        capabilityAuthority: SocketClientCapabilityAuthority,
        isDescendant: (pid_t) -> Bool
    ) -> Result? {
        switch accessMode {
        case .off:
            return nil
        case .cmuxOnly:
            guard let command = authorizedCommand(
                command,
                peerProcessID: peerProcessID,
                peerHasSameUID: peerHasSameUID,
                capabilityAuthority: capabilityAuthority,
                isDescendant: isDescendant
            ) else {
                return nil
            }
            return Result(command: command, bypassesPasswordAuthentication: false)
        case .automation:
            guard peerHasSameUID else { return nil }
            return Result(
                command: SocketClientCapabilityCommand(command)?.command ?? command,
                bypassesPasswordAuthentication: false
            )
        case .password:
            guard peerHasSameUID else { return nil }
            guard let envelope = SocketClientCapabilityCommand(command) else {
                return Result(command: command, bypassesPasswordAuthentication: false)
            }
            guard capabilityAuthority.verifies(envelope.capability),
                  Self.isPasswordTelemetryCommand(envelope.command) else {
                return nil
            }
            return Result(command: envelope.command, bypassesPasswordAuthentication: true)
        case .allowAll:
            return Result(
                command: SocketClientCapabilityCommand(command)?.command ?? command,
                bypassesPasswordAuthentication: false
            )
        }
    }

    private static func isPasswordTelemetryCommand(_ command: String) -> Bool {
        guard let commandName = command.split(whereSeparator: { $0.isWhitespace }).first else {
            return false
        }
        if commandName.hasPrefix("report_") {
            return true
        }
        return commandName == "ports_kick"
            || commandName == "clear_git_branch"
            || commandName == "clear_pr"
    }
}
