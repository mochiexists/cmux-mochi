import Bonsplit
import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Workspace right-side placement")
struct WorkspaceRightSidePlacementPlannerTests {
    @Test("a left-side source reuses the nearest pane to its right")
    func leftSideSourceReusesNearestRightPane() throws {
        let leftPaneID = UUID()
        let rightPaneID = UUID()
        let tree = ExternalTreeNode.split(
            ExternalSplitNode(
                id: UUID().uuidString,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: pane(id: leftPaneID, x: 0, width: 500),
                second: pane(id: rightPaneID, x: 500, width: 500)
            )
        )

        let placement = try #require(
            WorkspaceRightSidePlacementPlanner().plan(
                tree: tree,
                sourcePaneID: leftPaneID
            )
        )

        #expect(
            placement == .tab(
                targetPaneID: rightPaneID,
                strategy: .nearestRightSibling
            )
        )
    }

    @Test("a right-edge source reuses its pane instead of splitting it again")
    func rightEdgeSourceReusesItsPane() throws {
        let leftPaneID = UUID()
        let rightPaneID = UUID()
        let tree = ExternalTreeNode.split(
            ExternalSplitNode(
                id: UUID().uuidString,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: pane(id: leftPaneID, x: 0, width: 500),
                second: pane(id: rightPaneID, x: 500, width: 500)
            )
        )

        let placement = try #require(
            WorkspaceRightSidePlacementPlanner().plan(
                tree: tree,
                sourcePaneID: rightPaneID
            )
        )

        #expect(
            placement == .tab(
                targetPaneID: rightPaneID,
                strategy: .sourceRightEdge
            )
        )
    }

    private func pane(id: UUID, x: Double, width: Double) -> ExternalTreeNode {
        .pane(
            ExternalPaneNode(
                id: id.uuidString,
                frame: PixelRect(x: x, y: 0, width: width, height: 500),
                tabs: [],
                selectedTabId: nil
            )
        )
    }
}
