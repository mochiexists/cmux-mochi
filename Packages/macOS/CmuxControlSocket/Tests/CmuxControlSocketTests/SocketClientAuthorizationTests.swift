@testable import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

@Suite("Socket client authorization")
struct SocketClientAuthorizationTests {
    private let authorization = SocketClientAuthorization()

    @Test func cmuxOnlyFailsClosedWhenPeerPidIsUnavailable() {
        #expect(!authorization.isCmuxOnlyClientAllowed(
            peerProcessID: nil,
            peerHasSameUID: true,
            isDescendant: { _ in true }
        ))
    }

    @Test func cmuxOnlyAllowsDescendantPeerPid() {
        #expect(authorization.isCmuxOnlyClientAllowed(
            peerProcessID: 123,
            peerHasSameUID: false,
            isDescendant: { $0 == 123 }
        ))
    }

    @Test func cmuxOnlyRejectsNonDescendantPeerPid() {
        #expect(!authorization.isCmuxOnlyClientAllowed(
            peerProcessID: 123,
            peerHasSameUID: true,
            isDescendant: { _ in false }
        ))
    }

    @Test func cmuxOnlyAllowsReparentedClientWithInheritedCapability() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        let command = "hooks claude prompt-submit"

        #expect(authorization.authorizedCommand(
            envelope.wrap(command),
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == command)
    }

    @Test func cmuxOnlyRejectsReparentedClientWithoutCapability() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        #expect(authorization.authorizedCommand(
            "hooks claude prompt-submit",
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == nil)
    }

    @Test func cmuxOnlyRejectsCapabilityFromDifferentUser() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        #expect(authorization.authorizedCommand(
            envelope.wrap("hooks claude prompt-submit"),
            peerProcessID: 123,
            peerHasSameUID: false,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == nil)
    }

    @Test func ownerOnlyAutomationModesRejectDifferentUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )

        for mode in [SocketControlMode.automation, .password] {
            #expect(authorization.authorizedCommand(
                "ping",
                accessMode: mode,
                peerProcessID: nil,
                peerHasSameUID: false,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            ) == nil)
        }
    }

    @Test func ownerOnlyAutomationModesAllowSameUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )

        for mode in [SocketControlMode.automation, .password] {
            #expect(authorization.authorizedCommand(
                "ping",
                accessMode: mode,
                peerProcessID: nil,
                peerHasSameUID: true,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            ) == "ping")
        }
    }

    @Test func passwordFallsBackToPasswordAuthForCapabilityWrappedControlCommands() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))

        // The CLI wraps every command (including its own `auth <password>`
        // login line) whenever CMUX_SOCKET_CAPABILITY is set, so a denial
        // here locks the bundled CLI out of password-mode sockets entirely.
        for command in ["ping", "auth secret", "list-workspaces"] {
            let result = authorization.authorizationResult(
                envelope.wrap(command),
                accessMode: .password,
                peerProcessID: nil,
                peerHasSameUID: true,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            )
            #expect(result?.command == command)
            #expect(result?.bypassesPasswordAuthentication == false)
        }
    }

    @Test func passwordAllowsCapabilityWrappedShellTelemetry() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        let commands = [
            "report_tty /dev/ttys001",
            "report_shell_state running",
            "ports_kick prompt",
            "report_pwd /tmp",
            "report_git_branch main",
            "clear_git_branch",
            "report_pr 123",
            "report_pr_action 123 merge",
            "clear_pr",
        ]

        for command in commands {
            let result = authorization.authorizationResult(
                envelope.wrap(command),
                accessMode: .password,
                peerProcessID: nil,
                peerHasSameUID: true,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            )
            #expect(result?.command == command)
            #expect(result?.bypassesPasswordAuthentication == true)
        }
    }

    @Test func passwordDoesNotBypassAuthForInvalidCapabilityWrappedTelemetry() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: "not-a-valid-capability"))
        let command = "report_shell_state running --tab=test --panel=test"

        // An unverifiable capability grants nothing, but the command itself
        // is no more privileged than the same line sent unwrapped: it must
        // fall through to password authentication, not be denied outright.
        let result = authorization.authorizationResult(
            envelope.wrap(command),
            accessMode: .password,
            peerProcessID: nil,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        )
        #expect(result?.command == command)
        #expect(result?.bypassesPasswordAuthentication == false)
    }

    @Test func allowAllDoesNotRequireSameUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )

        #expect(authorization.authorizedCommand(
            "ping",
            accessMode: .allowAll,
            peerProcessID: nil,
            peerHasSameUID: false,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == "ping")
    }
}
