import Bonsplit
import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Workspace right-side placement")
struct WorkspaceRightSidePlacementPlannerTests {
    @Test("a full-width source is split once to establish a right side")
    func fullWidthSourceSplitsRight() throws {
        let sourcePaneID = UUID()
        let placement = try #require(WorkspaceRightSidePlacementPlanner().plan(
            tree: pane(id: sourcePaneID, x: 0, width: 1_000),
            sourcePaneID: sourcePaneID
        ))
        #expect(placement == .splitRight(
            sourcePaneID: sourcePaneID,
            strategy: .fullWidthSplit
        ))
    }

    @Test("a left-side source reuses the nearest pane to its right")
    func leftSideSourceReusesNearestRightPane() throws {
        let leftPaneID = UUID()
        let rightPaneID = UUID()
        let tree = split(
            orientation: "horizontal",
            first: pane(id: leftPaneID, x: 0, width: 500),
            second: pane(id: rightPaneID, x: 500, width: 500)
        )
        let placement = try #require(WorkspaceRightSidePlacementPlanner().plan(
            tree: tree,
            sourcePaneID: leftPaneID
        ))
        #expect(placement == .tab(
            targetPaneID: rightPaneID,
            strategy: .nearestRightSibling
        ))
    }

    @Test("headless split ancestry resolves before layout geometry exists")
    func headlessTreeUsesStructure() throws {
        let leftPaneID = UUID()
        let rightPaneID = UUID()
        let tree = split(
            orientation: "horizontal",
            first: pane(id: leftPaneID, x: 0, width: 0, height: 0),
            second: pane(id: rightPaneID, x: 0, width: 0, height: 0)
        )
        let placement = try #require(WorkspaceRightSidePlacementPlanner().plan(
            tree: tree,
            sourcePaneID: leftPaneID
        ))
        #expect(placement == .tab(
            targetPaneID: rightPaneID,
            strategy: .nearestRightSibling
        ))
    }

    @Test("a right-edge source reuses its pane instead of splitting again")
    func rightEdgeSourceReusesItsPane() throws {
        let leftPaneID = UUID()
        let rightPaneID = UUID()
        let tree = split(
            orientation: "horizontal",
            first: pane(id: leftPaneID, x: 0, width: 500),
            second: pane(id: rightPaneID, x: 500, width: 500)
        )
        let placement = try #require(WorkspaceRightSidePlacementPlanner().plan(
            tree: tree,
            sourcePaneID: rightPaneID
        ))
        #expect(placement == .tab(
            targetPaneID: rightPaneID,
            strategy: .sourceRightEdge
        ))
    }

    @Test("a grid source chooses the right pane on the same row")
    func gridSourceChoosesRightPaneOnSameRow() throws {
        let topLeftPaneID = UUID()
        let bottomLeftPaneID = UUID()
        let topRightPaneID = UUID()
        let bottomRightPaneID = UUID()
        let tree = split(
            orientation: "horizontal",
            first: split(
                orientation: "vertical",
                first: pane(id: topLeftPaneID, x: 0, y: 0, width: 500, height: 500),
                second: pane(id: bottomLeftPaneID, x: 0, y: 500, width: 500, height: 500)
            ),
            second: split(
                orientation: "vertical",
                first: pane(id: topRightPaneID, x: 500, y: 0, width: 500, height: 500),
                second: pane(id: bottomRightPaneID, x: 500, y: 500, width: 500, height: 500)
            )
        )
        let placement = try #require(WorkspaceRightSidePlacementPlanner().plan(
            tree: tree,
            sourcePaneID: topLeftPaneID
        ))
        #expect(placement == .tab(
            targetPaneID: topRightPaneID,
            strategy: .nearestRightSibling
        ))
    }

    @Test("vertically stacked full-width panes do not count as a right side")
    func verticalStackSplitsSourceRight() throws {
        let topPaneID = UUID()
        let bottomPaneID = UUID()
        let tree = split(
            orientation: "vertical",
            first: pane(id: topPaneID, x: 0, y: 0, width: 1_000, height: 500),
            second: pane(id: bottomPaneID, x: 0, y: 500, width: 1_000, height: 500)
        )
        let placement = try #require(WorkspaceRightSidePlacementPlanner().plan(
            tree: tree,
            sourcePaneID: topPaneID
        ))
        #expect(placement == .splitRight(
            sourcePaneID: topPaneID,
            strategy: .fullWidthSplit
        ))
    }

    @Test("a missing source has no placement")
    func missingSourceHasNoPlacement() {
        #expect(WorkspaceRightSidePlacementPlanner().plan(
            tree: pane(id: UUID(), x: 0, width: 1_000),
            sourcePaneID: UUID()
        ) == nil)
    }

    private func split(
        orientation: String,
        first: ExternalTreeNode,
        second: ExternalTreeNode
    ) -> ExternalTreeNode {
        .split(ExternalSplitNode(
            id: UUID().uuidString,
            orientation: orientation,
            dividerPosition: 0.5,
            first: first,
            second: second
        ))
    }

    private func pane(
        id: UUID,
        x: Double,
        y: Double = 0,
        width: Double,
        height: Double = 500
    ) -> ExternalTreeNode {
        .pane(ExternalPaneNode(
            id: id.uuidString,
            frame: PixelRect(x: x, y: y, width: width, height: height),
            tabs: [],
            selectedTabId: nil
        ))
    }
}
