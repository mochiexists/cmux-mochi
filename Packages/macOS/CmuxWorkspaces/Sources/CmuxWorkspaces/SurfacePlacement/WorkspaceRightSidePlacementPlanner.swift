public import Bonsplit
public import Foundation

/// Resolves adaptive right-side placement from an immutable workspace split tree.
public struct WorkspaceRightSidePlacementPlanner: Sendable {
    /// Creates a stateless placement planner.
    public init() {}

    /// Plans where to add a surface relative to a source pane.
    ///
    /// - Parameters:
    ///   - tree: Current immutable Bonsplit tree snapshot.
    ///   - sourcePaneID: Pane containing the surface that requested placement.
    /// - Returns: A placement when the source pane exists, otherwise `nil`.
    public func plan(
        tree: ExternalTreeNode,
        sourcePaneID: UUID
    ) -> WorkspaceRightSidePlacement? {
        guard let hasHorizontalAncestor = sourceHasHorizontalAncestor(
            in: tree,
            sourcePaneID: sourcePaneID,
            hasHorizontalAncestor: false
        ) else {
            return nil
        }

        if hasHorizontalAncestor {
            return .tab(
                targetPaneID: sourcePaneID,
                strategy: .sourceRightEdge
            )
        }

        return .splitRight(
            sourcePaneID: sourcePaneID,
            strategy: .fullWidthSplit
        )
    }

    private func sourceHasHorizontalAncestor(
        in node: ExternalTreeNode,
        sourcePaneID: UUID,
        hasHorizontalAncestor: Bool
    ) -> Bool? {
        switch node {
        case .pane(let pane):
            guard pane.id == sourcePaneID.uuidString else { return nil }
            return hasHorizontalAncestor
        case .split(let split):
            let nextHasHorizontalAncestor = hasHorizontalAncestor
                || split.orientation == "horizontal"
            return sourceHasHorizontalAncestor(
                in: split.first,
                sourcePaneID: sourcePaneID,
                hasHorizontalAncestor: nextHasHorizontalAncestor
            ) ?? sourceHasHorizontalAncestor(
                in: split.second,
                sourcePaneID: sourcePaneID,
                hasHorizontalAncestor: nextHasHorizontalAncestor
            )
        }
    }
}
