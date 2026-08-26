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

    /// Resolves how a mounted workspace should present based on selection and
    /// whether the workspace area is currently visible.
    ///
    /// Full-area pages are stacked with the workspace and fade its SwiftUI
    /// container. Terminal portals are hosted outside that tree, so they must be
    /// hidden explicitly whenever another page owns the workspace area.
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
