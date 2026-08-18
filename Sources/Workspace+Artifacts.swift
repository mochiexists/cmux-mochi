import AppKit
import Bonsplit
import CmuxWorkspaces
import Foundation

// MARK: - Artifact surfaces

// Fork (cmux Mochi): workspace-side entry points for the Artifacts panel —
// creating an artifact, opening or focusing its surface, and splitting a pane
// with one. Dropped by the rebase along with the rest of the feature.

extension Workspace {

    /// Scaffolds a new artifact in the global store and opens it. When `split` is
    /// provided, splits `paneId` in that direction (the "open beside me" path);
    /// otherwise adds a tab to `paneId`. Captures provenance from `originCwd`.
    @discardableResult
    func createArtifact(
        title: String,
        kind: ArtifactKind,
        inPane paneId: PaneID,
        split: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        originCwd: String?,
        originSurfaceId: String?,
        source: String? = nil,
        focus: Bool = true
    ) -> ArtifactPanel? {
        let origin = ArtifactStore.resolveOrigin(
            cwd: originCwd,
            workspaceId: id.uuidString,
            surfaceId: originSurfaceId
        )
        guard let created = try? ArtifactStore().createNew(
            title: title, kind: kind, origin: origin, source: source
        ) else {
            return nil
        }
        if let split {
            return splitPaneWithArtifact(
                targetPane: paneId,
                orientation: split.orientation,
                insertFirst: split.insertFirst,
                filePath: created.path,
                kind: kind,
                focus: focus
            )
        }
        return newArtifactSurface(inPane: paneId, filePath: created.path, kind: kind, focus: focus)
    }

    @discardableResult
    func openOrFocusArtifactSurface(
        inPane paneId: PaneID,
        filePath: String,
        kind: ArtifactKind? = nil,
        focus: Bool = true
    ) -> ArtifactPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let artifactPanel = panel as? ArtifactPanel else { continue }
            if (artifactPanel.filePath as NSString).resolvingSymlinksInPath == canonical {
                if focus {
                    focusPanel(existingId)
                }
                return artifactPanel
            }
        }

        return newArtifactSurface(inPane: paneId, filePath: filePath, kind: kind, focus: focus)
    }

    /// Splits `paneId` and renders an artifact in the new pane (the "open beside
    /// me" primitive used by the artifact CLI / conductor skill).
    @discardableResult
    func splitPaneWithArtifact(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String,
        kind: ArtifactKind? = nil,
        focus: Bool = true
    ) -> ArtifactPanel? {
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView
        let artifactPanel = ArtifactPanel(workspaceId: id, filePath: filePath, kind: kind)
        panels[artifactPanel.id] = artifactPanel
        panelTitles[artifactPanel.id] = artifactPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: artifactPanel.displayTitle,
            icon: artifactPanel.displayIcon,
            kind: SurfaceKind.artifact.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: artifactPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) else {
            panels.removeValue(forKey: artifactPanel.id)
            panelTitles.removeValue(forKey: artifactPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }

        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: artifactPanel.id, kind: SurfaceKind.artifact.rawValue, origin: "artifact_split", focused: focus)
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.artifactSplitReparent"
            )
            focusPanel(artifactPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: artifactPanel.id,
                previousHostedView: previousHostedView
            )
        }
        return artifactPanel
    }

    /// Opens an existing artifact source file as a new tab in `paneId`.
    @discardableResult
    func newArtifactSurface(
        inPane paneId: PaneID,
        filePath: String,
        kind: ArtifactKind? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> ArtifactPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let artifactPanel = ArtifactPanel(workspaceId: id, filePath: filePath, kind: kind)
        panels[artifactPanel.id] = artifactPanel
        panelTitles[artifactPanel.id] = artifactPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: artifactPanel.displayTitle,
            icon: artifactPanel.displayIcon,
            kind: SurfaceKind.artifact.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: artifactPanel.id)
            panelTitles.removeValue(forKey: artifactPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: artifactPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            artifactPanel.id, paneId: paneId,
            kind: SurfaceKind.artifact.rawValue, origin: "artifact_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: artifactPanel.id,
                previousHostedView: previousHostedView
            )
        }
        return artifactPanel
    }
}
