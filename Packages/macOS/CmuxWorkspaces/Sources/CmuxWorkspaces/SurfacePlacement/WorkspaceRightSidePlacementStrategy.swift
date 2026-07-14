/// Explains why an adaptive right-side placement selected its destination.
public enum WorkspaceRightSidePlacementStrategy: Equatable, Sendable {
    /// A new right split is required because the source spans the workspace width.
    case fullWidthSplit

    /// An existing pane in the nearest right sibling subtree is reused.
    case nearestRightSibling

    /// The source is already at the right edge, so its own tab bar is reused.
    case sourceRightEdge
}
