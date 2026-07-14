public import Bonsplit
public import Foundation

/// Resolves adaptive right-side placement from an immutable workspace split tree.
public struct WorkspaceRightSidePlacementPlanner: Sendable {
    private static let geometryTolerance = 0.5

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
        guard let source = sourcePane(
            in: tree,
            sourcePaneID: sourcePaneID,
            hasHorizontalAncestor: false
        ) else {
            return nil
        }

        if let targetPaneID = nearestRightPane(
            to: source.pane,
            in: tree
        ) {
            return .tab(
                targetPaneID: targetPaneID,
                strategy: .nearestRightSibling
            )
        }

        if source.hasHorizontalAncestor {
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

    private func sourcePane(
        in node: ExternalTreeNode,
        sourcePaneID: UUID,
        hasHorizontalAncestor: Bool
    ) -> SourcePane? {
        switch node {
        case .pane(let pane):
            guard pane.id == sourcePaneID.uuidString else { return nil }
            return SourcePane(
                pane: pane,
                hasHorizontalAncestor: hasHorizontalAncestor
            )
        case .split(let split):
            let nextHasHorizontalAncestor = hasHorizontalAncestor
                || split.orientation == "horizontal"
            return sourcePane(
                in: split.first,
                sourcePaneID: sourcePaneID,
                hasHorizontalAncestor: nextHasHorizontalAncestor
            ) ?? sourcePane(
                in: split.second,
                sourcePaneID: sourcePaneID,
                hasHorizontalAncestor: nextHasHorizontalAncestor
            )
        }
    }

    private func nearestRightPane(
        to source: ExternalPaneNode,
        in tree: ExternalTreeNode
    ) -> UUID? {
        let candidates = panes(in: tree).compactMap { pane -> RightPaneCandidate? in
            guard pane.id != source.id,
                  let paneID = UUID(uuidString: pane.id)
            else {
                return nil
            }

            let horizontalGap = pane.frame.x - (source.frame.x + source.frame.width)
            let verticalOverlap = min(
                source.frame.y + source.frame.height,
                pane.frame.y + pane.frame.height
            ) - max(source.frame.y, pane.frame.y)

            guard horizontalGap >= -Self.geometryTolerance,
                  verticalOverlap > Self.geometryTolerance
            else {
                return nil
            }

            let sourceCenterY = source.frame.y + (source.frame.height / 2)
            let paneCenterY = pane.frame.y + (pane.frame.height / 2)
            return RightPaneCandidate(
                paneID: paneID,
                horizontalGap: horizontalGap,
                verticalCenterDistance: abs(paneCenterY - sourceCenterY)
            )
        }

        return candidates.min { lhs, rhs in
            if lhs.horizontalGap != rhs.horizontalGap {
                return lhs.horizontalGap < rhs.horizontalGap
            }
            if lhs.verticalCenterDistance != rhs.verticalCenterDistance {
                return lhs.verticalCenterDistance < rhs.verticalCenterDistance
            }
            return lhs.paneID.uuidString < rhs.paneID.uuidString
        }?.paneID
    }

    private func panes(in node: ExternalTreeNode) -> [ExternalPaneNode] {
        switch node {
        case .pane(let pane):
            return [pane]
        case .split(let split):
            return panes(in: split.first) + panes(in: split.second)
        }
    }
}

private struct SourcePane {
    let pane: ExternalPaneNode
    let hasHorizontalAncestor: Bool
}

private struct RightPaneCandidate {
    let paneID: UUID
    let horizontalGap: Double
    let verticalCenterDistance: Double
}
