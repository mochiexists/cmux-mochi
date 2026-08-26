import CmuxFoundation
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct TaskManagerSurfaceParityTests {
    @Test func createsDetailedTaskManagerTabAndReusesExistingSurface() throws {
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)

        let first = try #require(
            workspace.openOrFocusTaskManagerSurface(inPane: paneID, focus: true)
        )
        let second = try #require(
            workspace.openOrFocusTaskManagerSurface(inPane: paneID, focus: true)
        )

        #expect(first === second)
        #expect(first.model.includesProcesses)
        #expect(workspace.focusedPanelId == first.id)
        #expect(workspace.panels.values.compactMap { $0 as? TaskManagerPanel }.count == 1)
        #expect(
            workspace.surfaceIdFromPanelId(first.id)
                .flatMap { workspace.bonsplitController.tab($0)?.kind }
                == SurfaceKind.taskManager.rawValue
        )
    }

    @Test func taskManagerSurfaceIsExcludedFromSnapshotAndRestore() throws {
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let taskManager = try #require(
            workspace.openOrFocusTaskManagerSurface(inPane: paneID, focus: true)
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        #expect(!snapshot.panels.contains { $0.id == taskManager.id })
        #expect(!snapshot.panels.contains { $0.type == .taskManager })

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        #expect(restored.panels.values.allSatisfy { !($0 is TaskManagerPanel) })
    }

    @Test func taskManagerSidebarSelectionPersistsAndRestoresAsTabs() {
        #expect(SessionSidebarSelection(selection: .taskManager) == .tabs)
        #expect(SessionSidebarSelection.tabs.sidebarSelection == .tabs)
    }

    @Test func fullAreaTaskManagerHidesSelectedAndRetiringWorkspacePortals() {
        let selected = MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: true,
            isRetiringWorkspace: false,
            isWorkspaceAreaVisible: false
        )
        let retiring = MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: false,
            isRetiringWorkspace: true,
            isWorkspaceAreaVisible: false
        )

        #expect(!selected.isRenderedVisible)
        #expect(!selected.isPanelVisible)
        #expect(selected.renderOpacity == 0)
        #expect(!retiring.isRenderedVisible)
        #expect(!retiring.isPanelVisible)
        #expect(retiring.renderOpacity == 0)
    }

    @Test func resourceSummaryRemainsVisibleInEveryWorkspacePresentationMode() {
        let minimalControls = SidebarFooterControl.allCases.filter {
            SidebarFooterPresentationPolicy.isVisible($0, presentationMode: .minimal)
        }
        let standardControls = SidebarFooterControl.allCases.filter {
            SidebarFooterPresentationPolicy.isVisible($0, presentationMode: .standard)
        }

        #expect(minimalControls == [.upgrade, .resourceSummary])
        #expect(standardControls == SidebarFooterControl.allCases)
    }
}
