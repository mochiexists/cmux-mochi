public import CmuxHive
public import CmuxMobilePairedMac
public import CmuxMobileShellModel
public import SwiftUI

/// Pairing, connection status, and remote workspace picker for Hive.
public struct HiveWorkspaceBrowserView: View {
    @Bindable private var coordinator: HiveWorkspaceCoordinator
    @State private var pairingLink = ""
    @State private var localOnlyRemoval: MobilePairedMac?
    @State private var removalError: String?
    private let openTerminal: @MainActor (
        MobileWorkspacePreview,
        MobileTerminalPreview
    ) -> Void

    public init(
        coordinator: HiveWorkspaceCoordinator,
        openTerminal: @escaping @MainActor (
            MobileWorkspacePreview,
            MobileTerminalPreview
        ) -> Void
    ) {
        self.coordinator = coordinator
        self.openTerminal = openTerminal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            pairingForm
            status
            workspaceList
            pairedComputers
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
        .task {
            if coordinator.hasKnownPairing {
                _ = await coordinator.reconnect()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                coordinator.refreshWorkspaceSnapshot()
            }
        }
        .confirmationDialog(
            String(localized: "hive.remove.localOnly.title", defaultValue: "Forget on this Mac?"),
            isPresented: Binding(
                get: { localOnlyRemoval != nil },
                set: { if !$0 { localOnlyRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "hive.remove.localOnly.action", defaultValue: "Forget Locally"),
                role: .destructive
            ) {
                guard let mac = localOnlyRemoval else { return }
                localOnlyRemoval = nil
                Task { await remove(mac, localOnly: true) }
            }
            Button(String(localized: "hive.cancel", defaultValue: "Cancel"), role: .cancel) {
                localOnlyRemoval = nil
            }
        } message: {
            Text(String(
                localized: "hive.remove.localOnly.message",
                defaultValue: "The remote Mac could not be reached to revoke this key. Its local authorization will remain inert until removed there."
            ))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "hive.title", defaultValue: "Remote Macs"))
                .font(.title2.bold())
            Text(String(
                localized: "hive.subtitle",
                defaultValue: "Pair another Mochi Mac and open its live workspaces over DeviceLink."
            ))
            .foregroundStyle(.secondary)
        }
    }

    private var pairingForm: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField(
                String(localized: "hive.pair.placeholder", defaultValue: "Paste pairing link"),
                text: $pairingLink,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1 ... 3)
            Button(String(localized: "hive.pair.action", defaultValue: "Pair")) {
                let link = pairingLink
                Task {
                    if await coordinator.pair(link: link) {
                        pairingLink = ""
                    }
                }
            }
            .disabled(pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch coordinator.phase {
        case .idle:
            EmptyView()
        case .pairing:
            Label(
                String(localized: "hive.status.pairing", defaultValue: "Pairing securely…"),
                systemImage: "lock.shield"
            )
        case .connecting:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "hive.status.connecting", defaultValue: "Connecting…"),
                    systemImage: "network"
                )
                connectionDetail
            }
        case .connected:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "hive.status.connected", defaultValue: "Authenticated with DeviceLink"),
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.green)
                connectionDetail
            }
        case let .pairedOffline(message, guidance):
            statusFailure(message: message, guidance: guidance)
        case let .failed(message, guidance):
            statusFailure(message: message, guidance: guidance)
        }
    }

    private func statusFailure(message: String, guidance: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if let guidance {
                Text(guidance).foregroundStyle(.secondary)
            }
            connectionDetail
            Button(String(localized: "hive.retry.action", defaultValue: "Retry")) {
                Task { _ = await coordinator.reconnect() }
            }
        }
    }

    @ViewBuilder
    private var connectionDetail: some View {
        if let detail = coordinator.connectionDetail {
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var workspaceList: some View {
        if coordinator.workspaces.isEmpty {
            ContentUnavailableView {
                Label(
                    String(localized: "hive.empty.title", defaultValue: "No Remote Workspaces"),
                    systemImage: "desktopcomputer"
                )
            } description: {
                Text(String(
                    localized: "hive.empty.description",
                    defaultValue: "Open Pair a Device on the other Mac, then paste its link above."
                ))
            }
        } else {
            List {
                ForEach(HiveComputerWorkspaceGroup.grouped(coordinator.workspaces)) { computer in
                    Section {
                        ForEach(computer.workspaces) { workspace in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(workspace.name).font(.headline)
                                ForEach(workspace.terminals) { terminal in
                                    Button {
                                        openTerminal(workspace, terminal)
                                    } label: {
                                        Label(terminal.name, systemImage: "terminal")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!terminal.isReady)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(computer.displayName)
                            if let instanceTag = computer.instanceTag, !instanceTag.isEmpty {
                                Text(instanceTag)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var pairedComputers: some View {
        if !coordinator.pairedMacs.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "hive.paired.title", defaultValue: "Paired Macs"))
                    .font(.headline)
                ForEach(coordinator.pairedMacs) { mac in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.resolvedName)
                            if let instanceTag = mac.instanceTag, !instanceTag.isEmpty {
                                Text(instanceTag)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(
                            String(localized: "hive.remove.action", defaultValue: "Remove"),
                            role: .destructive
                        ) {
                            Task { await remove(mac) }
                        }
                    }
                }
                if let removalError {
                    Text(removalError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func remove(_ mac: MobilePairedMac, localOnly: Bool = false) async {
        removalError = nil
        switch await coordinator.removePairing(mac, localOnly: localOnly) {
        case .removed:
            break
        case .requiresLocalOnlyConfirmation:
            localOnlyRemoval = mac
        case .failed:
            removalError = String(
                localized: "hive.remove.failed",
                defaultValue: "Could not remove this remote Mac."
            )
        }
    }
}
