public import CmuxMobileShellModel

/// Workspaces grouped by their authenticated remote Mac identity.
public struct HiveComputerWorkspaceGroup: Identifiable, Equatable, Sendable {
    public let deviceID: String
    public let displayName: String
    public let workspaces: [MobileWorkspacePreview]

    public var id: String { deviceID }

    public init(
        deviceID: String,
        displayName: String,
        workspaces: [MobileWorkspacePreview]
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.workspaces = workspaces
    }

    public static func grouped(
        _ workspaces: [MobileWorkspacePreview]
    ) -> [HiveComputerWorkspaceGroup] {
        let grouped = Dictionary(grouping: workspaces) {
            $0.macDeviceID ?? "unknown"
        }
        return grouped.map { deviceID, rows in
            HiveComputerWorkspaceGroup(
                deviceID: deviceID,
                displayName: rows.compactMap(\.macDisplayName).first
                    ?? String(deviceID.prefix(8)),
                workspaces: rows
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
