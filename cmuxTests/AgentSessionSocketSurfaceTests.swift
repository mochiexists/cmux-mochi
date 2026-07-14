import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AgentSessionSocketSurfaceTests {
    @Test
    func testNativeTranscriptSnapshotTracksProviderIdentityAndEntries() {
        let rendererSession = AgentSessionWebRendererSession()
        rendererSession.consumeProviderEvent([
            "type": "provider.transcript",
            "sessionId": "runtime-1",
            "providerId": "codex",
            "providerSessionId": "thread-1",
            "entries": [
                ["id": "user-1", "role": "user", "text": "say hi"],
                ["id": "agent-1", "role": "assistant", "text": "hi", "isComplete": true]
            ]
        ])
        rendererSession.consumeProviderEvent([
            "type": "provider.turnComplete",
            "sessionId": "runtime-1",
            "providerId": "codex",
            "providerSessionId": "thread-1",
            "turnId": "turn-1",
            "status": "completed"
        ])

        let snapshot = rendererSession.transcriptSnapshot()
        expectEqual(snapshot.text, "User: say hi\n\nAssistant: hi")
        expectEqual(snapshot.entries.count, 2)
        expectEqual(snapshot.providerID, "codex")
        expectEqual(snapshot.runtimeSessionID, "runtime-1")
        expectEqual(snapshot.providerSessionID, "thread-1")
        expectEqual(snapshot.turnID, "turn-1")
        expectEqual(snapshot.turnStatus, "completed")
    }

    @Test
    func testAgentTurnCompletionEventCarriesProviderAndTurnIdentity() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let workspaceID = UUID()
        let surfaceID = UUID()

        CmuxEventBus.shared.publishAgentTurnCompleted(
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            providerID: "codex",
            runtimeSessionID: "runtime-1",
            providerSessionID: "thread-1",
            turnID: "turn-1",
            status: "completed"
        )

        let event = try #require(CmuxEventBus.shared.retainedSnapshot().last)
        let payload = try #require(event["payload"] as? [String: Any])
        expectEqual(event["name"] as? String, "agent.turn.completed")
        expectEqual(payload["workspace_id"] as? String, workspaceID.uuidString)
        expectEqual(payload["surface_id"] as? String, surfaceID.uuidString)
        expectEqual(payload["provider_id"] as? String, "codex")
        expectEqual(payload["runtime_session_id"] as? String, "runtime-1")
        expectEqual(payload["provider_session_id"] as? String, "thread-1")
        expectEqual(payload["turn_id"] as? String, "turn-1")
        expectEqual(payload["status"] as? String, "completed")
    }

    @Test
    func testPanelTypeParserAcceptsAgentSessionSpellings() {
        let controller = TerminalController.shared

        for rawValue in [
            "agentSession", "agent-session", "agent_session", "agent session", "agentsession",
        ] {
            expectEqual(
                controller.v2PanelType(["type": rawValue], "type"),
                .agentSession,
                "Expected \(rawValue) to parse as an agent session surface"
            )
        }
    }

    @Test
    func testWorkspaceCreatesAgentSessionSurfaceWithProviderAndRenderer() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .opencode,
                rendererKind: .solid,
                workingDirectory: "/tmp",
                focus: true
            )
        )

        expectEqual(panel.panelType, .agentSession)
        expectEqual(panel.initialProviderID, .opencode)
        expectEqual(panel.rendererKind, .solid)
        expectEqual(panel.workingDirectory, "/tmp")
        expectFalse(panel.restoredFromSession)
        expectEqual(workspace.panelDirectories[panel.id], "/tmp")
        expectEqual(workspace.focusedPanelId, panel.id)
    }

    @Test
    func testWorkspaceSessionSnapshotPersistsAgentSessionWorkingDirectory() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .codex,
                rendererKind: .react,
                workingDirectory: "/tmp/cmux-agent-session-cwd",
                focus: true
            )
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })
        expectEqual(panelSnapshot.directory, "/tmp/cmux-agent-session-cwd")
        expectEqual(panelSnapshot.agentSession?.workingDirectory, "/tmp/cmux-agent-session-cwd")
    }

    @Test
    func testWorkspaceSessionSnapshotPersistsAttachedProviderSession() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let providerSessionID = "019dad34-d218-7943-b81a-eddac5c87951"

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .codex,
                rendererKind: .react,
                providerSessionID: providerSessionID,
                focus: false
            )
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })
        expectEqual(panel.providerSessionID, providerSessionID)
        expectEqual(panelSnapshot.agentSession?.providerSessionID, providerSessionID)
    }

    @Test
    func testWorkspaceRestoreMarksAgentSessionSurfaceAsRestored() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .codex,
                rendererKind: .react,
                workingDirectory: "/tmp/cmux-agent-session-restore",
                focus: true
            )
        )
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let restoredWorkspace = Workspace()

        let restoredPanelIds = restoredWorkspace.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[panel.id])
        let restoredPanel = try #require(restoredWorkspace.panels[restoredPanelId] as? AgentSessionPanel)

        expectTrue(restoredPanel.restoredFromSession)
        expectEqual(restoredPanel.initialProviderID, AgentSessionProviderID.codex)
        expectEqual(restoredPanel.rendererKind, AgentSessionRendererKind.react)
        expectEqual(restoredPanel.workingDirectory, "/tmp/cmux-agent-session-restore")
    }
}
