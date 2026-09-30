public import CmuxHive
public import CmuxMobilePairedMac
public import CmuxMobileShellModel
public import SwiftUI

/// Pairing, connection status, and remote workspace picker for Hive.
public struct HiveWorkspaceBrowserView: View {
    @Bindable private var coordinator: HiveWorkspaceCoordinator
    @State private var pairingLink = ""
    @State private var pendingRemoval: MobilePairedMac?
    @State private var localOnlyRemoval: MobilePairedMac?
    @State private var removalError: String?
    private let openTerminal: @MainActor (
        MobileWorkspacePreview,
        MobileTerminalPreview
    ) -> Void
    private let isTerminalMounted: @MainActor (
        MobileWorkspacePreview,
        MobileTerminalPreview
    ) -> Bool

    public init(
        coordinator: HiveWorkspaceCoordinator,
        openTerminal: @escaping @MainActor (
            MobileWorkspacePreview,
            MobileTerminalPreview
        ) -> Void,
        isTerminalMounted: @escaping @MainActor (
            MobileWorkspacePreview,
            MobileTerminalPreview
        ) -> Bool = { _, _ in false }
    ) {
        self.coordinator = coordinator
        self.openTerminal = openTerminal
        self.isTerminalMounted = isTerminalMounted
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
        .onAppear {
            coordinator.setBrowserVisible(true)
            #if DEBUG
            let fixture = ProcessInfo.processInfo.environment["CMUX_E2E_HIVE_UI_FIXTURE"]
            if fixture == "remove-confirmation" {
                pendingRemoval = coordinator.pairedMacs.first
            }
            #endif
        }
        .onDisappear { coordinator.setBrowserVisible(false) }
        .confirmationDialog(
            String(localized: "hive.remove.confirm.title", defaultValue: "Remove this remote Mac?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "hive.remove.confirm.action", defaultValue: "Remove Mac"),
                role: .destructive
            ) {
                guard let mac = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await remove(mac) }
            }
            Button(String(localized: "hive.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(String(
                localized: "hive.remove.confirm.message",
                defaultValue: "This Mac will need to be paired again before you can open its workspaces."
            ))
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
            .onSubmit { submitPairing() }
            Button {
                submitPairing()
            } label: {
                HStack(spacing: 6) {
                    if isPairing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(String(localized: "hive.pair.action", defaultValue: "Pair"))
                }
            }
            .disabled(!canSubmitPairing)
        }
    }

    private var isPairing: Bool {
        coordinator.phase == .pairing
    }

    private var canSubmitPairing: Bool {
        !isPairing
            && !pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitPairing() {
        guard canSubmitPairing else { return }
        let link = pairingLink
        Task {
            if await coordinator.pair(link: link) {
                pairingLink = ""
            }
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
            emptyState
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
                                        HStack(spacing: 8) {
                                            Label(terminal.name, systemImage: "terminal")
                                            Spacer()
                                            if !terminal.isReady {
                                                Text(String(
                                                    localized: "hive.terminal.notReady",
                                                    defaultValue: "Not ready"
                                                ))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            } else if isTerminalMounted(workspace, terminal) {
                                                Label(
                                                    String(localized: "hive.terminal.mounted", defaultValue: "Mounted"),
                                                    systemImage: "checkmark.circle.fill"
                                                )
                                                .font(.caption)
                                                .foregroundStyle(.green)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!terminal.isReady)
                                    .help(terminal.isReady ? "" : String(
                                        localized: "hive.terminal.notReady.help",
                                        defaultValue: "This terminal is still starting on the remote Mac."
                                    ))
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
    private var emptyState: some View {
        switch coordinator.emptyState ?? .neverPaired {
        case .neverPaired:
            ContentUnavailableView {
                Label(
                    String(localized: "hive.empty.neverPaired.title", defaultValue: "Pair Your First Mac"),
                    systemImage: "link.badge.plus"
                )
            } description: {
                Text(String(
                    localized: "hive.empty.neverPaired.description",
                    defaultValue: "Open Pair a Device on the other Mac, then paste its link above."
                ))
            }
        case .pairedOffline:
            ContentUnavailableView {
                Label(
                    String(localized: "hive.empty.offline.title", defaultValue: "Paired Macs Are Offline"),
                    systemImage: "wifi.slash"
                )
            } description: {
                Text(String(
                    localized: "hive.empty.offline.description",
                    defaultValue: "Open Mochi on a paired Mac, then connect to load its workspaces."
                ))
            }
        case .noWorkspaces:
            ContentUnavailableView {
                Label(
                    String(localized: "hive.empty.noWorkspaces.title", defaultValue: "No Workspaces on This Mac"),
                    systemImage: "rectangle.stack"
                )
            } description: {
                Text(String(
                    localized: "hive.empty.noWorkspaces.description",
                    defaultValue: "The remote Mac is connected but does not have an open workspace yet."
                ))
            }
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
                        pairedMacStatus(coordinator.connectionStatus(for: mac))
                        if coordinator.connectionStatus(for: mac) != .connected {
                            Button(String(localized: "hive.connect.action", defaultValue: "Connect")) {
                                Task { await coordinator.connect(mac) }
                            }
                            .disabled(coordinator.connectionStatus(for: mac) == .reconnecting)
                        }
                        Button(
                            String(localized: "hive.remove.action", defaultValue: "Remove"),
                            role: .destructive
                        ) {
                            pendingRemoval = mac
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

    private func pairedMacStatus(_ status: MobileMacConnectionStatus) -> some View {
        let presentation: (String, String, Color) = switch status {
        case .connected:
            (
                String(localized: "hive.mac.status.online", defaultValue: "Online"),
                "circle.fill",
                .green
            )
        case .reconnecting:
            (
                String(localized: "hive.mac.status.reconnecting", defaultValue: "Reconnecting"),
                "arrow.trianglehead.2.clockwise.rotate.90",
                .orange
            )
        case .unavailable:
            (
                String(localized: "hive.mac.status.offline", defaultValue: "Offline"),
                "circle.fill",
                .secondary
            )
        }
        return Label(presentation.0, systemImage: presentation.1)
            .font(.caption)
            .foregroundStyle(presentation.2)
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
