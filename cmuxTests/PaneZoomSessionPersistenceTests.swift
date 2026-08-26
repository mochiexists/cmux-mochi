import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Pane zoom session persistence", .serialized)
struct PaneZoomSessionPersistenceTests {
    @Test func zoomedPaneRoundTripsByStablePanelIdentity() throws {
        let source = Workspace()
        let leftPanelId = try #require(source.focusedPanelId)
        let rightPanel = try #require(
            source.newTerminalSplit(
                from: leftPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let rightPaneId = try #require(source.paneId(forPanelId: rightPanel.id))

        #expect(source.bonsplitController.togglePaneZoom(inPane: rightPaneId))
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.zoomedPanelId == rightPanel.id)

        let restored = Workspace()
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredRightPanelId = try #require(restoredPanelIds[rightPanel.id])
        let restoredRightPaneId = try #require(restored.paneId(forPanelId: restoredRightPanelId))

        #expect(restored.bonsplitController.zoomedPaneId == restoredRightPaneId)
        #expect(restored.panels[restoredRightPanelId] != nil)
    }

    @Test func unzoomedWorkspaceRoundTripsWithoutInventingZoom() throws {
        let source = Workspace()
        let leftPanelId = try #require(source.focusedPanelId)
        _ = try #require(
            source.newTerminalSplit(
                from: leftPanelId,
                orientation: .horizontal,
                focus: false
            )
        )

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.zoomedPanelId == nil)

        let restored = Workspace()
        _ = restored.restoreSessionSnapshot(snapshot)

        #expect(restored.bonsplitController.zoomedPaneId == nil)
        #expect(restored.bonsplitController.allPaneIds.count == 2)
    }

    @Test func zoomedPaneWithMultipleSurfacesRestoresTheContainingPane() throws {
        let source = Workspace()
        let leftPanelId = try #require(source.focusedPanelId)
        let rightPanel = try #require(
            source.newTerminalSplit(
                from: leftPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let rightPaneId = try #require(source.paneId(forPanelId: rightPanel.id))
        let secondRightPanel = try #require(
            source.newTerminalSurface(inPane: rightPaneId, focus: false)
        )

        #expect(source.bonsplitController.togglePaneZoom(inPane: rightPaneId))
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let persistedZoomPanelId = try #require(snapshot.zoomedPanelId)
        #expect(persistedZoomPanelId == rightPanel.id || persistedZoomPanelId == secondRightPanel.id)

        let restored = Workspace()
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredZoomPanelId = try #require(restoredPanelIds[persistedZoomPanelId])
        let expectedPaneId = try #require(restored.paneId(forPanelId: restoredZoomPanelId))

        #expect(restored.bonsplitController.zoomedPaneId == expectedPaneId)
        #expect(restored.bonsplitController.tabs(inPane: expectedPaneId).count == 2)
    }
}
