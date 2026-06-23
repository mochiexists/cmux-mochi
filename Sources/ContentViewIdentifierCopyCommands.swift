import CmuxCommandPalette
import AppKit
import Foundation

private struct IdentifierCommandDescriptor {
    let id: String
    let title: String
    let keywords: [String]
    let requiresPane: Bool
}

extension ContentView {
    func appendIdentifierCopyCommandContributions(
        to contributions: inout [CommandPaletteCommandContribution],
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        panelSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        let workspaceCommands = [
            IdentifierCommandDescriptor(
                id: "palette.copyWorkspaceID",
                title: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
                keywords: ["copy", "workspace", "id", "identifier"],
                requiresPane: false
            ),
            IdentifierCommandDescriptor(
                id: "palette.copyWorkspaceIDAndRef",
                title: String(localized: "command.copyWorkspaceIDAndRef.title", defaultValue: "Copy Workspace ID and Ref"),
                keywords: ["copy", "workspace", "id", "identifier", "ref", "reference"],
                requiresPane: false
            ),
            IdentifierCommandDescriptor(
                id: "palette.copyWorkspaceLink",
                title: String(localized: "command.copyWorkspaceLink.title", defaultValue: "Copy Workspace Link"),
                keywords: ["copy", "workspace", "link", "url", "deeplink", "deep link"],
                requiresPane: false
            )
        ]
        contributions += workspaceCommands.map { command in
            CommandPaletteCommandContribution(
                commandId: command.id,
                title: constant(command.title),
                subtitle: workspaceSubtitle,
                keywords: command.keywords,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        }

        let panelCommands = [
            IdentifierCommandDescriptor(
                id: "palette.copyPaneID",
                title: String(localized: "command.copyPaneID.title", defaultValue: "Copy Pane ID"),
                keywords: ["copy", "pane", "split", "id", "identifier"],
                requiresPane: true
            ),
            IdentifierCommandDescriptor(
                id: "palette.copyPaneLink",
                title: String(localized: "command.copyPaneLink.title", defaultValue: "Copy Pane Link"),
                keywords: ["copy", "pane", "split", "link", "url", "deeplink", "deep link"],
                requiresPane: true
            ),
            IdentifierCommandDescriptor(
                id: "palette.copySurfaceID",
                title: String(localized: "command.copySurfaceID.title", defaultValue: "Copy Surface ID"),
                keywords: ["copy", "surface", "tab", "id", "identifier"],
                requiresPane: false
            ),
            IdentifierCommandDescriptor(
                id: "palette.copySurfaceLink",
                title: String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
                keywords: ["copy", "surface", "tab", "link", "url", "deeplink", "deep link"],
                requiresPane: false
            ),
            IdentifierCommandDescriptor(
                id: "palette.copyIdentifiers",
                title: String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs"),
                keywords: ["copy", "ids", "identifiers", "workspace", "pane", "surface", "ref", "reference"],
                requiresPane: false
            ),
            IdentifierCommandDescriptor(
                id: "palette.showIdentifiers",
                title: String(localized: "terminalContextMenu.showIdentifiers", defaultValue: "Show IDs"),
                keywords: ["show", "ids", "identifiers", "workspace", "pane", "surface", "agent", "session", "resume"],
                requiresPane: false
            )
        ]
        contributions += panelCommands.map { command in
            CommandPaletteCommandContribution(
                commandId: command.id,
                title: constant(command.title),
                subtitle: panelSubtitle,
                keywords: command.keywords,
                when: {
                    command.requiresPane
                        ? $0.bool(CommandPaletteContextKeys.panelHasPane)
                        : $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                }
            )
        }
    }

    func registerIdentifierCopyCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.copyWorkspaceID") { copySelectedWorkspaceIdentifiers(includeRefs: false) }
        registry.register(commandId: "palette.copyWorkspaceIDAndRef") { copySelectedWorkspaceIdentifiers(includeRefs: true) }
        registry.register(commandId: "palette.copyWorkspaceLink") { copySelectedWorkspaceLink() }
        registry.register(commandId: "palette.copyPaneID") { copyFocusedPaneIdentifier() }
        registry.register(commandId: "palette.copyPaneLink") { copyFocusedPaneLink() }
        registry.register(commandId: "palette.copySurfaceID") { copyFocusedSurfaceIdentifier() }
        registry.register(commandId: "palette.copySurfaceLink") { copyFocusedSurfaceLink() }
        registry.register(commandId: "palette.copyIdentifiers") { copyFocusedWorkspacePaneSurfaceIdentifiers() }
        registry.register(commandId: "palette.showIdentifiers") { showFocusedWorkspacePaneSurfaceIdentifiers() }
    }

    private func copySelectedWorkspaceIdentifiers(includeRefs: Bool) {
        guard let workspaceId = tabManager.selectedWorkspace?.id else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds([workspaceId], includeRefs: includeRefs)
    }

    private func copySelectedWorkspaceLink() {
        guard let workspaceId = tabManager.selectedWorkspace?.id else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspaceLink(workspaceId: workspaceId)
        )
    }

    private func focusedPanelIdentifierContext() -> (workspaceId: UUID, paneId: UUID?, surfaceId: UUID)? {
        guard let panelContext = focusedPanelContext else { return nil }
        return (
            workspaceId: panelContext.workspace.id,
            paneId: panelContext.workspace.paneId(forPanelId: panelContext.panelId)?.id,
            surfaceId: panelContext.panelId
        )
    }

    private func focusedPanelAgentSnapshot(workspaceId: UUID, surfaceId: UUID) -> SessionRestorableAgentSnapshot? {
        if let panelContext = focusedPanelContext,
           panelContext.workspace.id == workspaceId,
           panelContext.panelId == surfaceId,
           let snapshot = panelContext.workspace.forkableAgentSnapshot(forPanelId: surfaceId) {
            return snapshot
        }
        return SharedLiveAgentIndex.shared.snapshot(workspaceId: workspaceId, panelId: surfaceId)
    }

    private func copyFocusedPaneIdentifier() {
        guard let paneId = focusedPanelIdentifierContext()?.paneId else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(WorkspaceSurfaceIdentifierClipboardText.makePane(paneId: paneId))
    }

    private func copyFocusedPaneLink() {
        guard let context = focusedPanelIdentifierContext(),
              let paneId = context.paneId else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makePaneLink(
                workspaceId: context.workspaceId,
                paneId: paneId
            )
        )
    }

    private func copyFocusedSurfaceIdentifier() {
        guard let context = focusedPanelIdentifierContext() else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(WorkspaceSurfaceIdentifierClipboardText.makeSurface(surfaceId: context.surfaceId))
    }

    private func copyFocusedSurfaceLink() {
        guard let context = focusedPanelIdentifierContext() else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: context.workspaceId,
                surfaceId: context.surfaceId
            )
        )
    }

    private func copyFocusedWorkspacePaneSurfaceIdentifiers() {
        guard let context = focusedPanelIdentifierContext() else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: context.workspaceId,
                paneId: context.paneId,
                surfaceId: context.surfaceId,
                includeRefs: true,
                agent: focusedPanelAgentSnapshot(workspaceId: context.workspaceId, surfaceId: context.surfaceId)
            )
        )
    }

    private func showFocusedWorkspacePaneSurfaceIdentifiers() {
        guard let context = focusedPanelIdentifierContext() else {
            NSSound.beep()
            return
        }
        SurfaceIdentifierDetailsWindowController.shared.show(
            details: WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifierDetails(
                workspaceId: context.workspaceId,
                paneId: context.paneId,
                surfaceId: context.surfaceId,
                includeRefs: true,
                agent: focusedPanelAgentSnapshot(workspaceId: context.workspaceId, surfaceId: context.surfaceId)
            )
        )
    }
}
