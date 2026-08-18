import Testing
@testable import CmuxFoundation

/// A full-area surface replacing the workspace must leave nothing of the
/// workspace visible.
///
/// Task Manager and Notifications are stacked with the workspace and shown by
/// fading the workspace to `opacity(0)`, not by unmounting it. Terminals render
/// in an AppKit portal hoisted out of the SwiftUI tree, so that opacity never
/// reaches them: without this gate the terminal keeps drawing over whichever
/// surface replaced it and both sets of text land in the same pixels.
@Test func hidesTheWorkspaceEntirelyWhenAnotherSurfaceOwnsTheArea() {
    let hidden = MountedWorkspacePresentation.resolve(
        isSelectedWorkspace: true,
        isRetiringWorkspace: false,
        isWorkspaceAreaVisible: false
    )
    #expect(hidden.isPanelVisible == false)
    #expect(hidden.isRenderedVisible == false)
    #expect(hidden.renderOpacity == 0)
}

/// The selected workspace still presents normally while it owns the area, and
/// the default keeps every existing caller unchanged.
@Test func presentsTheSelectedWorkspaceWhenItOwnsTheArea() {
    let shown = MountedWorkspacePresentation.resolve(
        isSelectedWorkspace: true,
        isRetiringWorkspace: false,
        isWorkspaceAreaVisible: true
    )
    #expect(shown.isPanelVisible)
    #expect(shown.renderOpacity == 1)

    let defaulted = MountedWorkspacePresentation.resolve(
        isSelectedWorkspace: true,
        isRetiringWorkspace: false
    )
    #expect(defaulted == shown)
}

/// A retiring workspace stays visible during handoff — but not when another
/// surface owns the area, or it would bleed through the same way.
@Test func retiringWorkspaceStillHidesWhenAnotherSurfaceOwnsTheArea() {
    #expect(
        MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: false,
            isRetiringWorkspace: true,
            isWorkspaceAreaVisible: true
        ).isRenderedVisible
    )
    #expect(
        MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: false,
            isRetiringWorkspace: true,
            isWorkspaceAreaVisible: false
        ).isRenderedVisible == false
    )
}
