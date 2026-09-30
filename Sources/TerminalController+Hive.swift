import CmuxHive
import CmuxMobileShell
import Foundation

extension TerminalController {
    @MainActor
    func v2HivePair(params: [String: Any]) async -> V2CallResult {
        guard let link = params["link"] as? String,
              !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.hive.missingLink", defaultValue: "Missing pairing link"),
                data: nil
            )
        }
        guard let coordinator = AppDelegate.shared?.hiveWorkspaceService.coordinator else {
            return hiveUnavailableResult()
        }
        let paired = await coordinator.pair(link: link)
        guard paired else {
            return .err(
                code: "pairing_failed",
                message: hivePhaseMessage(coordinator.phase) ?? String(
                    localized: "socket.hive.pairingFailed",
                    defaultValue: "Could not pair with the remote Mac"
                ),
                data: hiveStatusPayload(coordinator: coordinator)
            )
        }
        return .ok(hiveStatusPayload(coordinator: coordinator))
    }

    @MainActor
    func v2HiveList() -> V2CallResult {
        guard let coordinator = AppDelegate.shared?.hiveWorkspaceService.coordinator else {
            return hiveUnavailableResult()
        }
        coordinator.refreshWorkspaceSnapshot()
        return .ok(hiveStatusPayload(coordinator: coordinator))
    }

    @MainActor
    func v2HiveOpen(params: [String: Any]) -> V2CallResult {
        guard let workspaceID = params["workspace_id"] as? String,
              !workspaceID.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.hive.missingWorkspace", defaultValue: "Missing workspace_id"),
                data: nil
            )
        }
        guard let service = AppDelegate.shared?.hiveWorkspaceService,
              service.coordinator != nil else {
            return hiveUnavailableResult()
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(
                code: "unavailable",
                message: String(localized: "socket.tabManager.unavailable", defaultValue: "TabManager not available"),
                data: nil
            )
        }
        let requestedSurfaceID = params["surface_id"] as? String
        guard let opened = service.open(
            workspaceID: workspaceID,
            surfaceID: requestedSurfaceID,
            in: tabManager
        ), let workspace = tabManager.workspacesById[opened.workspaceID] else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.hive.workspaceNotFound",
                    defaultValue: "Remote workspace or terminal not found"
                ),
                data: ["workspace_id": workspaceID]
            )
        }
        let surfaces = opened.localPanelIDsByRemoteSurfaceID.compactMapValues { panelID in
            workspace.terminalPanel(for: panelID)?.surface.id.uuidString
        }
        return .ok([
            "workspace_id": opened.workspaceID.uuidString,
            "surface_ids": surfaces,
            "focused": false,
        ])
    }

    @MainActor
    func v2HiveStatus() async -> V2CallResult {
        guard let coordinator = AppDelegate.shared?.hiveWorkspaceService.coordinator else {
            return hiveUnavailableResult()
        }
        if coordinator.hasKnownPairing, hivePhaseCanStartReconnect(coordinator.phase) {
            _ = await coordinator.reconnect()
        } else {
            coordinator.refreshWorkspaceSnapshot()
        }
        return .ok(hiveStatusPayload(coordinator: coordinator))
    }

    @MainActor
    func v2HiveRemove(params: [String: Any]) async -> V2CallResult {
        guard let pairingID = params["pairing_id"] as? String,
              !pairingID.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.hive.missingPairing", defaultValue: "Missing pairing_id"),
                data: nil
            )
        }
        guard let coordinator = AppDelegate.shared?.hiveWorkspaceService.coordinator else {
            return hiveUnavailableResult()
        }
        guard let pairing = coordinator.pairedMacs.first(where: { $0.id == pairingID }) else {
            return .err(
                code: "not_found",
                message: String(localized: "socket.hive.pairedMacNotFound", defaultValue: "Paired Mac not found"),
                data: ["pairing_id": pairingID]
            )
        }
        let localOnly = (params["local_only"] as? Bool) ?? false
        let result = await coordinator.removePairing(pairing, localOnly: localOnly)
        switch result {
        case .removed:
            return .ok([
                "removed": true,
                "pairing_id": pairingID,
                "local_only": localOnly,
            ])
        case .requiresLocalOnlyConfirmation:
            return .err(
                code: "confirmation_required",
                message: String(
                    localized: "socket.hive.localOnlyConfirmation",
                    defaultValue: "The remote Mac is unavailable; retry with local_only to forget it locally"
                ),
                data: ["pairing_id": pairingID]
            )
        case .failed:
            return .err(
                code: "remove_failed",
                message: String(localized: "socket.hive.removeFailed", defaultValue: "Could not remove the paired Mac"),
                data: ["pairing_id": pairingID]
            )
        }
    }

    @MainActor
    private func hiveStatusPayload(
        coordinator: HiveWorkspaceCoordinator
    ) -> [String: Any] {
        let pairedMacs: [[String: Any]] = coordinator.pairedMacs.map { mac in
            [
                "id": mac.id,
                "device_id": mac.macDeviceID,
                "instance_tag": mac.instanceTag ?? NSNull(),
                "name": mac.resolvedName,
                "route_count": mac.routes.count,
            ]
        }
        let workspaces: [[String: Any]] = coordinator.workspaces.map { workspace in
            [
                "id": workspace.id.rawValue,
                "remote_workspace_id": workspace.rpcWorkspaceID.rawValue,
                "name": workspace.name,
                "mac_device_id": workspace.macDeviceID ?? NSNull(),
                "mac_instance_tag": workspace.macInstanceTag ?? NSNull(),
                "mac_name": workspace.macDisplayName ?? NSNull(),
                "terminals": workspace.terminals.map { terminal in
                    [
                        "id": terminal.id.rawValue,
                        "name": terminal.name,
                        "ready": terminal.isReady,
                    ] as [String: Any]
                },
            ]
        }
        let attachments: [[String: Any]] = (
            AppDelegate.shared?.hiveWorkspaceService.attachmentStatus() ?? []
        ).map { attachment in
            [
                "remote_workspace_id": attachment.remoteWorkspaceID,
                "remote_surface_id": attachment.remoteSurfaceID,
                "local_mount_count": attachment.localMountCount,
                "remote_registration_count": attachment.remoteRegistrationCount,
            ]
        }
        return [
            "phase": hivePhaseName(coordinator.phase),
            "connected": coordinator.phase == .connected,
            "has_pairing": coordinator.hasKnownPairing,
            "message": hivePhaseMessage(coordinator.phase) ?? NSNull(),
            "connection_detail": coordinator.connectionDetail ?? NSNull(),
            "paired_macs": pairedMacs,
            "workspaces": workspaces,
            "attachments": attachments,
        ]
    }

    private func hivePhaseName(_ phase: HiveWorkspaceCoordinator.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .pairing: "pairing"
        case .connecting: "connecting"
        case .connected: "connected"
        case .pairedOffline: "paired_offline"
        case .failed: "failed"
        }
    }

    private func hivePhaseCanStartReconnect(_ phase: HiveWorkspaceCoordinator.Phase) -> Bool {
        switch phase {
        case .idle, .pairedOffline, .failed:
            true
        case .pairing, .connecting, .connected:
            false
        }
    }

    private func hivePhaseMessage(_ phase: HiveWorkspaceCoordinator.Phase) -> String? {
        switch phase {
        case .pairedOffline(let message, _), .failed(let message, _): message
        default: nil
        }
    }

    private func hiveUnavailableResult() -> V2CallResult {
        .err(
            code: "unavailable",
            message: String(localized: "socket.hive.unavailable", defaultValue: "Hive is unavailable"),
            data: nil
        )
    }
}
