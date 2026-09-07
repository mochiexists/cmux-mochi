public import CmuxMobileShellModel

/// Workspaces grouped by their authenticated remote Mac identity.
public struct HiveComputerWorkspaceGroup: Identifiable, Equatable, Sendable {
    public let deviceID: String
    public let instanceTag: String?
    public let displayName: String
    public let workspaces: [MobileWorkspacePreview]

    public var id: String { "\(deviceID)\u{1F}\(instanceTag ?? "")" }

    public init(
        deviceID: String,
        instanceTag: String?,
        displayName: String,
        workspaces: [MobileWorkspacePreview]
    ) {
        self.deviceID = deviceID
        self.instanceTag = instanceTag
        self.displayName = displayName
        self.workspaces = workspaces
    }

    public static func grouped(
        _ workspaces: [MobileWorkspacePreview]
    ) -> [HiveComputerWorkspaceGroup] {
        let grouped = Dictionary(grouping: workspaces) { workspace in
            ComputerKey(
                deviceID: workspace.macDeviceID ?? "unknown",
                instanceTag: workspace.macInstanceTag
            )
        }
        return grouped.map { key, rows in
            HiveComputerWorkspaceGroup(
                deviceID: key.deviceID,
                instanceTag: key.instanceTag,
                displayName: rows.compactMap(\.macDisplayName).first
                    ?? String(key.deviceID.prefix(8)),
                workspaces: rows
            )
        }
        .sorted {
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return ($0.instanceTag ?? "").localizedCaseInsensitiveCompare(
                $1.instanceTag ?? ""
            ) == .orderedAscending
        }
    }
}

private struct ComputerKey: Hashable {
    let deviceID: String
    let instanceTag: String?
}
