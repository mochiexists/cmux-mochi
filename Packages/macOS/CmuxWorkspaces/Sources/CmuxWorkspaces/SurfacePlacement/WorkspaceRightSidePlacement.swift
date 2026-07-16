public import Foundation

/// Describes where a new surface should appear for an adaptive “beside right” request.
public enum WorkspaceRightSidePlacement: Equatable, Sendable {
    /// Add the surface as a tab in an existing pane.
    case tab(
        targetPaneID: UUID,
        strategy: WorkspaceRightSidePlacementStrategy
    )

    /// Split the source pane once to establish a right-side destination.
    case splitRight(
        sourcePaneID: UUID,
        strategy: WorkspaceRightSidePlacementStrategy
    )
}
