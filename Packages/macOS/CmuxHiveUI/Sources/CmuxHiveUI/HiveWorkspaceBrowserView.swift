public import CmuxHive
public import CmuxMobileShellModel
public import SwiftUI

/// Pairing, connection status, and remote workspace picker for Hive.
public struct HiveWorkspaceBrowserView: View {
    @Bindable private var coordinator: HiveWorkspaceCoordinator
    @State private var pairingLink = ""
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
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
        .task {
            _ = await coordinator.reconnect()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                coordinator.refreshWorkspaceSnapshot()
            }
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
            Label(
                String(localized: "hive.status.connecting", defaultValue: "Connecting…"),
                systemImage: "network"
            )
        case .connected:
            Label(
                String(localized: "hive.status.connected", defaultValue: "Authenticated with DeviceLink"),
                systemImage: "checkmark.shield"
            )
            .foregroundStyle(.green)
        case let .failed(message, guidance):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if let guidance {
                    Text(guidance).foregroundStyle(.secondary)
                }
            }
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
                    Section(computer.displayName) {
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
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
