import Bonsplit
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Resolves the shared adaptive placement policy against this workspace's
    /// current split tree.
    func rightSidePlacement(fromPanelId panelId: UUID) -> WorkspaceRightSidePlacement? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        return WorkspaceRightSidePlacementPlanner().plan(
            tree: bonsplitController.treeSnapshot(),
            sourcePaneID: sourcePane.id
        )
    }

    /// Returns the pane that should receive a new tab for adaptive right-side
    /// placement. A `nil` result tells the caller to split the source pane.
    func preferredRightSideTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard case .tab(let targetPaneID, _) = rightSidePlacement(fromPanelId: panelId) else {
            return nil
        }
        return bonsplitController.allPaneIds.first { $0.id == targetPaneID }
    }
}
