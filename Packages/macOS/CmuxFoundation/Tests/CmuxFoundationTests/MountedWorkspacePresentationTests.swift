import Testing
@testable import CmuxFoundation

@Suite struct MountedWorkspacePresentationTests {
    @Test func fullAreaPageHidesSelectedWorkspaceAndTerminalPortal() {
        let presentation = MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: true,
            isRetiringWorkspace: false,
            isWorkspaceAreaVisible: false
        )

        #expect(!presentation.isPanelVisible)
        #expect(!presentation.isRenderedVisible)
        #expect(presentation.renderOpacity == 0)
    }

    @Test func selectedWorkspacePresentsNormallyWhenItOwnsArea() {
        let explicit = MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: true,
            isRetiringWorkspace: false,
            isWorkspaceAreaVisible: true
        )
        let defaulted = MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: true,
            isRetiringWorkspace: false
        )

        #expect(explicit.isPanelVisible)
        #expect(explicit.isRenderedVisible)
        #expect(explicit.renderOpacity == 1)
        #expect(defaulted == explicit)
    }

    @Test func fullAreaPageAlsoHidesRetiringWorkspace() {
        let presentation = MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: false,
            isRetiringWorkspace: true,
            isWorkspaceAreaVisible: false
        )

        #expect(!presentation.isPanelVisible)
        #expect(!presentation.isRenderedVisible)
        #expect(presentation.renderOpacity == 0)
    }
}
