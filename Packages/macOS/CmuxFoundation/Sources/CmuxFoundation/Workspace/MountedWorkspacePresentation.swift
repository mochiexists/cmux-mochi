/// The resolved visibility/opacity a mounted workspace should present with.
/// Pure value type holding no state and touching no UI.
public struct MountedWorkspacePresentation: Equatable {
    public let isRenderedVisible: Bool
    public let isPanelVisible: Bool
    public let renderOpacity: Double

    public init(
        isRenderedVisible: Bool,
        isPanelVisible: Bool,
        renderOpacity: Double
    ) {
        self.isRenderedVisible = isRenderedVisible
        self.isPanelVisible = isPanelVisible
        self.renderOpacity = renderOpacity
    }

    /// Resolves how a mounted workspace should present based on whether it is the
    /// selected or retiring workspace.
    /// - Parameter isWorkspaceAreaVisible: Whether the workspace area is on
    ///   screen at all. Full-area surfaces (Task Manager, Notifications) replace
    ///   it, and they are stacked with the workspace rather than swapped for it,
    ///   so the workspace is merely faded to `opacity(0)`. Terminals render in an
    ///   AppKit portal hoisted out of the SwiftUI tree, which that opacity cannot
    ///   touch — so without this the terminal keeps drawing on top of whichever
    ///   surface replaced it, and the two sets of text share the same pixels.
    public static func resolve(
        isSelectedWorkspace: Bool,
        isRetiringWorkspace: Bool,
        isWorkspaceAreaVisible: Bool = true
    ) -> MountedWorkspacePresentation {
        guard isWorkspaceAreaVisible else {
            return MountedWorkspacePresentation(
                isRenderedVisible: false,
                isPanelVisible: false,
                renderOpacity: 0
            )
        }
        let isRenderedVisible = isSelectedWorkspace || isRetiringWorkspace

        return MountedWorkspacePresentation(
            isRenderedVisible: isRenderedVisible,
            isPanelVisible: isRenderedVisible,
            renderOpacity: isRenderedVisible ? 1 : 0
        )
    }
}
