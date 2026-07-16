import Foundation
import Testing
@testable import CmuxControlSocket

/// Behavior coverage for the live-foreground-job send guard: it must block only
/// on positive evidence of a non-agent foreground job (fail-open), honor every
/// agent exemption, and always yield to `force`.
@Suite("ControlSurfaceSendGuard")
struct ControlSurfaceSendGuardTests {
    @Test("blocks a live non-agent foreground job")
    func blocksLiveJob() {
        #expect(ControlSurfaceSendGuard.blocksTextSend(
            isCommandRunning: true,
            hasAgentEvidence: false,
            foregroundCommandName: "sudo",
            force: false
        ))
        #expect(ControlSurfaceSendGuard.blocksTextSend(
            isCommandRunning: true,
            hasAgentEvidence: false,
            foregroundCommandName: "xcodebuild",
            force: false
        ))
    }

    @Test("fails open when the shell is idle or unreported")
    func failsOpenWhenIdle() {
        // promptIdle / unknown both arrive here as isCommandRunning == false.
        #expect(!ControlSurfaceSendGuard.blocksTextSend(
            isCommandRunning: false,
            hasAgentEvidence: false,
            foregroundCommandName: "sudo",
            force: false
        ))
    }

    @Test("fails open when the foreground name is unresolvable but no job is reported")
    func failsOpenOnNilNameWhenNotRunning() {
        #expect(!ControlSurfaceSendGuard.blocksTextSend(
            isCommandRunning: false,
            hasAgentEvidence: false,
            foregroundCommandName: nil,
            force: false
        ))
    }

    @Test("blocks a running job whose name cannot be resolved")
    func blocksRunningJobWithUnresolvableName() {
        // A live job with no name evidence is still a live job; only agent
        // evidence or force may unblock it.
        #expect(ControlSurfaceSendGuard.blocksTextSend(
            isCommandRunning: true,
            hasAgentEvidence: false,
            foregroundCommandName: nil,
            force: false
        ))
    }

    @Test("agent evidence exempts the pane")
    func agentEvidenceExempts() {
        #expect(!ControlSurfaceSendGuard.blocksTextSend(
            isCommandRunning: true,
            hasAgentEvidence: true,
            foregroundCommandName: "some-build-tool",
            force: false
        ))
    }

    @Test("known agent CLI foreground names exempt the pane, case-insensitively")
    func agentForegroundNameExempts() {
        for name in ["claude", "codex", "node", "Claude", "CODEX", "ovm"] {
            #expect(!ControlSurfaceSendGuard.blocksTextSend(
                isCommandRunning: true,
                hasAgentEvidence: false,
                foregroundCommandName: name,
                force: false
            ), "expected \(name) to be exempt")
        }
    }

    @Test("force always wins")
    func forceAlwaysWins() {
        #expect(!ControlSurfaceSendGuard.blocksTextSend(
            isCommandRunning: true,
            hasAgentEvidence: false,
            foregroundCommandName: "sudo",
            force: true
        ))
    }
}
