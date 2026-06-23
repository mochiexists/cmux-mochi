import AppKit
import Foundation

enum WorkspaceSurfaceIdentifierClipboardText {
    @MainActor
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    static func copyWorkspaceIds(_ ids: [UUID], includeRefs: Bool) {
        copy(makeWorkspaceIds(ids, includeRefs: includeRefs))
    }

    @MainActor
    static func copyWorkspaceLinks(_ ids: [UUID]) {
        copy(makeWorkspaceLinks(ids))
    }

    @MainActor
    static func makeWorkspaceIds(_ ids: [UUID], includeRefs: Bool) -> String {
        let refs = includeRefs ? TerminalController.shared.v2WorkspaceRefs(for: ids) : [:]
        return make(workspaces: ids.map { (id: $0, ref: refs[$0]) })
    }

    static func makePane(paneId: UUID, paneRef: String? = nil) -> String {
        var lines: [String] = []
        if let paneRef {
            lines.append("pane_ref=\(paneRef)")
        }
        lines.append("pane_id=\(paneId.uuidString)")
        return lines.joined(separator: "\n")
    }

    static func makeSurface(surfaceId: UUID, surfaceRef: String? = nil) -> String {
        var lines: [String] = []
        if let surfaceRef {
            lines.append("surface_ref=\(surfaceRef)")
        }
        lines.append("surface_id=\(surfaceId.uuidString)")
        return lines.joined(separator: "\n")
    }

    static func makeWorkspaceLink(workspaceId: UUID) -> String {
        CmuxNavigationURLRequest.workspaceLink(workspaceId: workspaceId)
    }

    static func makeWorkspaceLinks(_ ids: [UUID]) -> String {
        ids.map { makeWorkspaceLink(workspaceId: $0) }.joined(separator: "\n")
    }

    static func makePaneLink(workspaceId: UUID, paneId: UUID) -> String {
        CmuxNavigationURLRequest.paneLink(workspaceId: workspaceId, paneId: paneId)
    }

    static func makeSurfaceLink(workspaceId: UUID, surfaceId: UUID) -> String {
        CmuxNavigationURLRequest.surfaceLink(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    @MainActor
    static func makeWorkspacePaneSurfaceIdentifiers(
        workspaceId: UUID,
        paneId: UUID?,
        surfaceId: UUID,
        includeRefs: Bool = true,
        agent: SessionRestorableAgentSnapshot? = nil
    ) -> String {
        makeWorkspacePaneSurfaceIdentifierDetails(
            workspaceId: workspaceId,
            paneId: paneId,
            surfaceId: surfaceId,
            includeRefs: includeRefs,
            agent: agent
        ).clipboardText
    }

    @MainActor
    static func makeWorkspacePaneSurfaceIdentifierDetails(
        workspaceId: UUID,
        paneId: UUID?,
        surfaceId: UUID,
        includeRefs: Bool = true,
        agent: SessionRestorableAgentSnapshot? = nil
    ) -> WorkspaceSurfaceIdentifierDetails {
        let refs = includeRefs
            ? TerminalController.shared.v2WorkspacePaneAndSurfaceRefs(
                workspaceId: workspaceId,
                paneId: paneId,
                surfaceId: surfaceId
            )
            : nil
        return makeDetails(
            workspaceId: workspaceId,
            paneId: paneId,
            surfaceId: surfaceId,
            workspaceRef: refs?.workspaceRef,
            paneRef: refs?.paneRef,
            surfaceRef: refs?.surfaceRef,
            agent: agent
        )
    }

    static func make(workspaceId: UUID, workspaceRef: String? = nil) -> String {
        var lines: [String] = []
        if let workspaceRef {
            lines.append("workspace_ref=\(workspaceRef)")
        }
        lines.append("workspace_id=\(workspaceId.uuidString)")
        return lines.joined(separator: "\n")
    }

    static func make(workspaceIds: [UUID]) -> String {
        workspaceIds.map { make(workspaceId: $0) }.joined(separator: "\n\n")
    }

    static func make(workspaces: [(id: UUID, ref: String?)]) -> String {
        workspaces
            .map { make(workspaceId: $0.id, workspaceRef: $0.ref) }
            .joined(separator: "\n\n")
    }

    static func make(
        workspaceId: UUID,
        paneId: UUID? = nil,
        surfaceId: UUID,
        workspaceRef: String? = nil,
        paneRef: String? = nil,
        surfaceRef: String? = nil,
        agent: SessionRestorableAgentSnapshot? = nil
    ) -> String {
        var lines: [String] = []
        if let workspaceRef {
            lines.append("workspace_ref=\(workspaceRef)")
        }
        lines.append("workspace_id=\(workspaceId.uuidString)")
        if let paneRef {
            lines.append("pane_ref=\(paneRef)")
        }
        if let paneId {
            lines.append("pane_id=\(paneId.uuidString)")
        }
        if let surfaceRef {
            lines.append("surface_ref=\(surfaceRef)")
        }
        lines.append("surface_id=\(surfaceId.uuidString)")
        if let agent {
            lines.append("agent_name=\(agent.agentDisplayName)")
            lines.append("agent_kind=\(agent.kind.rawValue)")
            if let launcher = agent.launchCommand?.launcher {
                lines.append("agent_launcher=\(launcher)")
            }
            if let source = agent.launchCommand?.source {
                lines.append("agent_launch_source=\(source)")
            }
            lines.append("session_id=\(agent.sessionId)")
            if let workingDirectory = agent.workingDirectory {
                lines.append("working_directory=\(workingDirectory)")
            }
            if let resumeCommand = agent.resumeCommand {
                lines.append("resume_command=\(resumeCommand)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func makeDetails(
        workspaceId: UUID,
        paneId: UUID? = nil,
        surfaceId: UUID,
        workspaceRef: String? = nil,
        paneRef: String? = nil,
        surfaceRef: String? = nil,
        agent: SessionRestorableAgentSnapshot? = nil
    ) -> WorkspaceSurfaceIdentifierDetails {
        var rows: [WorkspaceSurfaceIdentifierDetails.Row] = []
        rows.append(.init(section: .refs, key: "workspace_ref", value: workspaceRef))
        rows.append(.init(section: .ids, key: "workspace_id", value: workspaceId.uuidString))
        rows.append(.init(section: .refs, key: "pane_ref", value: paneRef))
        rows.append(.init(section: .ids, key: "pane_id", value: paneId?.uuidString))
        rows.append(.init(section: .refs, key: "surface_ref", value: surfaceRef))
        rows.append(.init(section: .ids, key: "surface_id", value: surfaceId.uuidString))
        rows.append(.init(section: .agent, key: "agent_name", value: agent?.agentDisplayName))
        rows.append(.init(section: .agent, key: "agent_kind", value: agent?.kind.rawValue))
        rows.append(.init(section: .agent, key: "agent_launcher", value: agent?.launchCommand?.launcher))
        rows.append(.init(section: .agent, key: "agent_launch_source", value: agent?.launchCommand?.source))
        rows.append(.init(section: .agent, key: "session_id", value: agent?.sessionId))
        rows.append(.init(section: .agent, key: "working_directory", value: agent?.workingDirectory))
        rows.append(.init(section: .agent, key: "resume_command", value: agent?.resumeCommand))
        return WorkspaceSurfaceIdentifierDetails(rows: rows)
    }
}
