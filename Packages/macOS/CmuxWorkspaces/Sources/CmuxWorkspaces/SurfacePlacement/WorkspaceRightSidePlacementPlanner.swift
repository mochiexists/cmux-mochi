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
            sourcePaneID: sourcePaneID
        ) else {
            return nil
        }

        if let targetPaneID = nearestRightPane(to: source) {
            return .tab(
                targetPaneID: targetPaneID,
                strategy: .nearestRightSibling
            )
        }

        if source.ancestors.contains(where: { $0.split.orientation == "horizontal" }) {
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
        sourcePaneID: UUID
    ) -> SourcePane? {
        switch node {
        case .pane(let pane):
            guard pane.id == sourcePaneID.uuidString else { return nil }
            return SourcePane(pane: pane, ancestors: [])
        case .split(let split):
            if var source = sourcePane(
                in: split.first,
                sourcePaneID: sourcePaneID
            ) {
                source.ancestors.append(SplitAncestor(split: split, branch: .first))
                return source
            }
            if var source = sourcePane(
                in: split.second,
                sourcePaneID: sourcePaneID
            ) {
                source.ancestors.append(SplitAncestor(split: split, branch: .second))
                return source
            }
            return nil
        }
    }

    private func nearestRightPane(to source: SourcePane) -> UUID? {
        for ancestor in source.ancestors {
            guard ancestor.split.orientation == "horizontal",
                  ancestor.branch == .first else {
                continue
            }
            let panesToRight = panes(in: ancestor.split.second)
            if let targetPaneID = bestAlignedPane(
                to: source.pane,
                candidates: panesToRight
            ) {
                return targetPaneID
            }
        }
        return nil
    }

    private func bestAlignedPane(
        to source: ExternalPaneNode,
        candidates: [ExternalPaneNode]
    ) -> UUID? {
        let sourceHasGeometry = source.frame.width > Self.geometryTolerance
            && source.frame.height > Self.geometryTolerance
        let alignedCandidates = candidates.filter { pane in
            guard sourceHasGeometry,
                  pane.frame.width > Self.geometryTolerance,
                  pane.frame.height > Self.geometryTolerance else {
                return false
            }
            let verticalOverlap = min(
                source.frame.y + source.frame.height,
                pane.frame.y + pane.frame.height
            ) - max(source.frame.y, pane.frame.y)
            return verticalOverlap > Self.geometryTolerance
        }
        let candidatesToRank = alignedCandidates.isEmpty ? candidates : alignedCandidates
        let sourceCenterY = source.frame.y + (source.frame.height / 2)
        let sourceRightX = source.frame.x + source.frame.width

        let ranked = candidatesToRank.compactMap { pane -> RightPaneCandidate? in
            guard let paneID = UUID(uuidString: pane.id) else { return nil }
            let paneCenterY = pane.frame.y + (pane.frame.height / 2)
            return RightPaneCandidate(
                paneID: paneID,
                horizontalGap: abs(pane.frame.x - sourceRightX),
                verticalCenterDistance: abs(paneCenterY - sourceCenterY)
            )
        }

        return ranked.min { lhs, rhs in
            if lhs.verticalCenterDistance != rhs.verticalCenterDistance {
                return lhs.verticalCenterDistance < rhs.verticalCenterDistance
            }
            if lhs.horizontalGap != rhs.horizontalGap {
                return lhs.horizontalGap < rhs.horizontalGap
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
    var ancestors: [SplitAncestor]
}

private struct SplitAncestor {
    let split: ExternalSplitNode
    let branch: SplitBranch
}

private enum SplitBranch {
    case first
    case second
}

private struct RightPaneCandidate {
    let paneID: UUID
    let horizontalGap: Double
    let verticalCenterDistance: Double
}
