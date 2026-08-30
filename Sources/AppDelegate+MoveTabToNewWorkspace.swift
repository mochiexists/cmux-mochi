import Foundation
import Bonsplit
import CmuxSettings

struct SurfaceNewWorkspaceMoveResult {
    let sourceWindowId: UUID
    let sourceWorkspaceId: UUID
    let destinationWindowId: UUID?
    let destinationWorkspaceId: UUID
    let surfaceId: UUID
    let paneId: UUID?
}

struct SurfaceBatchNewWorkspaceMoveResult {
    let sourceWindowId: UUID
    let sourceWorkspaceId: UUID
    let destinationWindowId: UUID?
    let destinationWorkspaceId: UUID
    let surfaceIds: [UUID]
    let paneId: UUID?
}

@MainActor
extension AppDelegate {
    private struct BonsplitBatchSource {
        let tabId: UUID
        let panelId: UUID
        let workspaceId: UUID
        let paneId: PaneID
        let index: Int
        let tabManager: TabManager
        let windowId: UUID
    }

    private func bonsplitBatchSources(tabIds: [UUID]) -> [BonsplitBatchSource]? {
        let uniqueTabIds = tabIds.reduce(into: [UUID]()) { result, tabId in
            if !result.contains(tabId) {
                result.append(tabId)
            }
        }
        guard !uniqueTabIds.isEmpty else { return nil }

        var sources: [BonsplitBatchSource] = []
        for tabId in uniqueTabIds {
            guard let located = locateBonsplitSurface(tabId: tabId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  workspace.panels[located.panelId] != nil,
                  let paneId = workspace.paneId(forPanelId: located.panelId),
                  let index = workspace.indexInPane(forPanelId: located.panelId) else {
                return nil
            }
            sources.append(BonsplitBatchSource(
                tabId: tabId,
                panelId: located.panelId,
                workspaceId: located.workspaceId,
                paneId: paneId,
                index: index,
                tabManager: located.tabManager,
                windowId: located.windowId
            ))
        }

        guard let first = sources.first,
              sources.allSatisfy({
                  $0.workspaceId == first.workspaceId
                      && $0.paneId == first.paneId
                      && $0.tabManager === first.tabManager
              }) else {
            return nil
        }
        return sources.sorted { $0.index < $1.index }
    }

    func canMoveBonsplitTabs(tabIds: [UUID], toWorkspace targetWorkspaceId: UUID) -> Bool {
        guard let sources = bonsplitBatchSources(tabIds: tabIds),
              let destinationManager = tabManagerFor(tabId: targetWorkspaceId),
              destinationManager.tabs.contains(where: { $0.id == targetWorkspaceId }) else {
            return false
        }
        return sources.allSatisfy { canMoveBonsplitTab(tabId: $0.tabId, toWorkspace: targetWorkspaceId) }
    }

    func canMoveBonsplitTabsToNewWorkspace(tabIds: [UUID]) -> Bool {
        guard let sources = bonsplitBatchSources(tabIds: tabIds),
              let first = sources.first,
              let workspace = first.tabManager.tabs.first(where: { $0.id == first.workspaceId }) else {
            return false
        }
        return workspace.panels.count > sources.count
    }

    @discardableResult
    func moveBonsplitTabs(
        tabIds: [UUID],
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
        guard let sources = bonsplitBatchSources(tabIds: tabIds),
              let first = sources.first else { return false }
        if first.workspaceId == targetWorkspaceId,
           targetPane == nil,
           splitTarget == nil {
            return true
        }
        guard canMoveBonsplitTabs(
            tabIds: sources.map(\.tabId),
            toWorkspace: targetWorkspaceId
        ) else { return false }

        var moved: [BonsplitBatchSource] = []
        var resolvedPane = targetPane
        for (offset, source) in sources.enumerated() {
            let movedSuccessfully = moveBonsplitTab(
                tabId: source.tabId,
                toWorkspace: targetWorkspaceId,
                targetPane: resolvedPane,
                targetIndex: targetIndex.map { $0 + offset },
                splitTarget: offset == 0 ? splitTarget : nil,
                focus: false,
                focusWindow: false
            )
            guard movedSuccessfully else {
                rollbackBonsplitBatch(moved.reversed())
                return false
            }
            moved.append(source)
            if resolvedPane == nil,
               let destination = workspaceFor(tabId: targetWorkspaceId) {
                resolvedPane = destination.paneId(forPanelId: source.panelId)
            }
        }

        if focus,
           let destinationManager = tabManagerFor(tabId: targetWorkspaceId) {
            if focusWindow, let destinationWindowId = windowId(for: destinationManager) {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            destinationManager.focusTab(
                targetWorkspaceId,
                surfaceId: first.panelId,
                suppressFlash: true
            )
        }
        return true
    }

    @discardableResult
    func moveBonsplitTabsToNewWorkspace(
        tabIds: [UUID],
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceBatchNewWorkspaceMoveResult? {
        guard let sources = bonsplitBatchSources(tabIds: tabIds),
              let first = sources.first,
              canMoveBonsplitTabsToNewWorkspace(tabIds: sources.map(\.tabId)),
              let firstResult = moveBonsplitTabToNewWorkspace(
                  tabId: first.tabId,
                  destinationManager: destinationManager,
                  title: title,
                  focus: false,
                  focusWindow: false,
                  placementOverride: placementOverride,
                  insertionIndexOverride: insertionIndexOverride
              ) else {
            return nil
        }

        var moved = [first]
        for source in sources.dropFirst() {
            guard moveBonsplitTab(
                tabId: source.tabId,
                toWorkspace: firstResult.destinationWorkspaceId,
                targetPane: firstResult.paneId.map(PaneID.init(id:)),
                focus: false,
                focusWindow: false
            ) else {
                rollbackBonsplitBatch(moved.reversed())
                return nil
            }
            moved.append(source)
        }

        let targetManager = destinationManager ?? first.tabManager
        if focus {
            if focusWindow, let destinationWindowId = windowId(for: targetManager) {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            targetManager.focusTab(
                firstResult.destinationWorkspaceId,
                surfaceId: first.panelId,
                suppressFlash: true
            )
        }

        return SurfaceBatchNewWorkspaceMoveResult(
            sourceWindowId: first.windowId,
            sourceWorkspaceId: first.workspaceId,
            destinationWindowId: windowId(for: targetManager),
            destinationWorkspaceId: firstResult.destinationWorkspaceId,
            surfaceIds: sources.map(\.panelId),
            paneId: firstResult.paneId
        )
    }

    private func rollbackBonsplitBatch<S: Sequence>(_ sources: S)
    where S.Element == BonsplitBatchSource {
        for source in sources {
            _ = moveBonsplitTab(
                tabId: source.tabId,
                toWorkspace: source.workspaceId,
                targetPane: source.paneId,
                targetIndex: source.index,
                focus: false,
                focusWindow: false
            )
        }
    }

    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              sourceWorkspace.panels[panelId] != nil else {
            return false
        }
        return sourceWorkspace.panels.count > 1
    }

    func canMoveBonsplitTabToNewWorkspace(tabId: UUID) -> Bool {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return false }
        return canMoveSurfaceToNewWorkspace(panelId: located.panelId)
    }

    func canMoveBonsplitTab(tabId: UUID, toWorkspace targetWorkspaceId: UUID) -> Bool {
        guard let located = locateBonsplitSurface(tabId: tabId),
              let sourceWorkspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              sourceWorkspace.panels[located.panelId] != nil,
              let destinationManager = tabManagerFor(tabId: targetWorkspaceId),
              destinationManager.tabs.contains(where: { $0.id == targetWorkspaceId }) else {
            return false
        }
        return true
    }

    func workspaceMoveTargets(forSurface panelId: UUID) -> [WorkspaceMoveTarget] {
        guard let source = locateSurface(surfaceId: panelId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: source.workspaceId,
            referenceWindowId: source.windowId
        )
    }

    func workspaceMoveTargets(forBonsplitTab tabId: UUID) -> [WorkspaceMoveTarget] {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: located.workspaceId,
            referenceWindowId: located.windowId
        )
    }

    @discardableResult
    func moveBonsplitTabToNewWorkspace(
        tabId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return nil }
        return moveSurfaceToNewWorkspace(
            panelId: located.panelId,
            destinationManager: destinationManager,
            title: title,
            focus: focus,
            focusWindow: focusWindow,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride
        )
    }

    @discardableResult
    func moveSurfaceToNewWorkspace(
        panelId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let sourcePanel = sourceWorkspace.panels[panelId],
              sourceWorkspace.panels.count > 1 else {
            return nil
        }

        let targetManager = destinationManager ?? source.tabManager
        let hasExplicitTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !hasExplicitTitle {
            source.tabManager.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
        }
        let destinationTitle = titleForDetachedWorkspace(
            explicitTitle: title,
            workspace: sourceWorkspace,
            panelId: panelId,
            panel: sourcePanel
        )
        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
        let activationIntent = focusIntentForNewWorkspaceMove(panel: sourcePanel)
        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else { return nil }

        guard let destinationWorkspace = targetManager.addWorkspace(
            fromDetachedSurface: detached,
            title: destinationTitle,
            titleSource: hasExplicitTitle ? .user : .auto,
            select: false,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride,
            focusIntent: activationIntent
        ) else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
            return nil
        }

        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: targetManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            targetManager.focusTab(
                destinationWorkspace.id,
                surfaceId: panelId,
                suppressFlash: true,
                focusIntent: activationIntent
            )
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: source.windowId,
                    destinationWorkspaceId: destinationWorkspace.id,
                    destinationPanelId: panelId,
                    destinationManager: targetManager
                )
            }
        }

        return SurfaceNewWorkspaceMoveResult(
            sourceWindowId: source.windowId,
            sourceWorkspaceId: source.workspaceId,
            destinationWindowId: windowId(for: targetManager),
            destinationWorkspaceId: destinationWorkspace.id,
            surfaceId: panelId,
            paneId: destinationWorkspace.paneId(forPanelId: panelId)?.id
        )
    }

    private func focusIntentForNewWorkspaceMove(panel: any Panel) -> PanelFocusIntent {
        if panel is BrowserPanel {
            // Moving a browser tab into a standalone workspace should expose browser chrome,
            // even if web content was the last in-panel responder before the drag.
            return .browser(.addressBar)
        }
        return panel.preferredFocusIntentForActivation()
    }

    private func titleForDetachedWorkspace(
        explicitTitle: String?,
        workspace: Workspace,
        panelId: UUID,
        panel: any Panel
    ) -> String {
        let trimmedTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let fallbackTitle = workspace.panelTitle(panelId: panelId) ?? panel.displayTitle
        let trimmedFallbackTitle = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallbackTitle.isEmpty {
            return trimmedFallbackTitle
        }

        return String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
    }
}
