import CMUXMobileCore
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Mobile** section — Mac-side controls for pairing and syncing with
/// cmux on iOS: the pairing-host toggle, the preferred listener port (with a
/// live bound-port indicator), an optional display-name override, and
/// connection/route diagnostics.
@MainActor
public struct MobileSection: View {
    @State private var iOSPairingHost: DefaultsValueModel<Bool>
    @State private var port: DefaultsValueModel<Int>
    @State private var displayName: DefaultsValueModel<String>
    @State private var artifactFolderAccess: DefaultsValueModel<MobileArtifactFolderAccess>
    @State private var status: MobilePairingStatusModel

    /// The user's in-progress port edit, or `nil` when the field should track
    /// the persisted value. Local so editing does not rebind the listener; only
    /// the **Apply** button does, after checking the port is free. `nil` lets the
    /// field reflect `port.current` once `DefaultsValueModel` has loaded the
    /// saved value (it seeds the catalog default first, then yields the real one).
    @State private var editedPort: Int?
    /// Result of the most recent Apply, shown inline. Cleared when the edit changes.
    @State private var applyResult: MobilePairingPortApplyResult?
    /// Guards against overlapping Apply taps while a probe is in flight.
    @State private var isApplying = false

    /// What each advertised route's connect-back proved, keyed by route id.
    /// Routes absent from this map render as
    /// ``CmxRouteReachability/unverified`` — never as reachable, which is the
    /// point of verifying instead of trusting interface enumeration.
    @State private var routeReachability: [String: CmxRouteReachability] = [:]
    /// True while a verification pass is running, so the Check button can't
    /// stack passes and the user sees the work is in flight.
    @State private var isVerifyingRoutes = false

    /// Host bridge: opens the pairing window, applies the port (availability
    /// checked), and supplies the live pairing status and default display name.
    private let hostActions: SettingsHostActions

    private static let columnWidth: CGFloat = 196

    /// Creates a Mobile settings section bound to the supplied settings stores.
    ///
    /// - Parameters:
    ///   - defaultsStore: UserDefaults-backed store for the pairing settings.
    ///   - catalog: The settings catalog defining the mobile keys.
    ///   - hostActions: Host bridge for the pairing window, port apply, and the
    ///     live pairing status the package can't produce itself.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        _iOSPairingHost = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingHost))
        _port = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingPort))
        _displayName = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingDisplayName))
        _artifactFolderAccess = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: catalog.mobile.artifactFolderAccess
        ))
        _status = State(initialValue: MobilePairingStatusModel(hostActions: hostActions))
        self.hostActions = hostActions
    }

    /// The value shown in the field: the user's edit if any, otherwise the
    /// persisted port (which updates once it loads).
    private var draftPort: Int {
        editedPort ?? port.current
    }

    /// The port currently in effect: the bound port when running, otherwise the
    /// persisted preference. Apply is offered only when the draft differs from it.
    private var effectivePort: Int {
        status.current?.boundPort ?? port.current
    }

    private var isDraftValid: Bool {
        (1...65535).contains(draftPort)
    }

    /// The Mobile settings section content.
    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.mobile", defaultValue: "Mobile"), section: .mobile)
            SettingsCard {
                pairDeviceRow
                SettingsCardDivider()
                iOSPairingHostRow
                SettingsCardDivider()
                portRow
                boundPortStatusRow
                SettingsCardDivider()
                displayNameRow
                SettingsCardDivider()
                artifactFolderAccessRow
                if iOSPairingHost.current {
                    SettingsCardDivider()
                    diagnostics
                }
                SettingsCardNote(String(
                    localized: "settings.mobile.port.note",
                    defaultValue: "Click Apply to change the port. cmux checks the port is free first: if it's in use, the current listener keeps running untouched; if it's free, it rebinds and connected devices reconnect on the new port."
                ))
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            iOSPairingHost,
            port,
            displayName,
            artifactFolderAccess,
            status,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var pairDeviceRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:mobile:pairDevice",
            String(localized: "settings.mobile.pairDevice", defaultValue: "Pair a Device"),
            subtitle: String(localized: "settings.mobile.pairDevice.subtitle", defaultValue: "Show a QR code to pair your iPhone or iPad with this Mac.")
        ) {
            Button(String(localized: "settings.mobile.pairDevice.button", defaultValue: "Pair…")) {
                hostActions.openMobilePairingWindow()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsMobilePairDeviceButton")
        }
    }

    @ViewBuilder
    private var iOSPairingHostRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:iOSPairingHost",
            String(localized: "settings.mobile.iOSPairingHost", defaultValue: "iOS Pairing"),
            subtitle: iOSPairingHost.current
                ? String(localized: "settings.mobile.iOSPairingHost.subtitleOn", defaultValue: "Allows the iOS app to discover and sync with this Mac on your local network.")
                : String(localized: "settings.mobile.iOSPairingHost.subtitleOff", defaultValue: "Keeps the Mac-side iOS pairing listener off until you enable it here.")
        ) {
            Toggle("", isOn: Binding(get: { iOSPairingHost.current }, set: { iOSPairingHost.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMobileIOSPairingHostToggle")
        }
    }

    @ViewBuilder
    private var portRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:iOSPairingPort",
            String(localized: "settings.mobile.port", defaultValue: "Pairing Port"),
            subtitle: String(localized: "settings.mobile.port.subtitle", defaultValue: "Preferred TCP port for the iOS pairing listener (1–65535).")
        ) {
            HStack(spacing: 8) {
                TextField(
                    "",
                    value: Binding(get: { draftPort }, set: { editedPort = $0 }),
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .onChange(of: editedPort) { applyResult = nil }
                .onSubmit { applyDraftPort() }
                .accessibilityIdentifier("SettingsMobilePairingPortField")

                Button(String(localized: "settings.mobile.port.apply", defaultValue: "Apply")) {
                    applyDraftPort()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isApplying || !isDraftValid || draftPort == effectivePort)
                .accessibilityIdentifier("SettingsMobilePairingPortApplyButton")
            }
        }
    }

    private func applyDraftPort() {
        let requested = draftPort
        guard !isApplying, isDraftValid, requested != effectivePort else { return }
        isApplying = true
        Task {
            let result = await hostActions.applyMobilePairingPort(requested)
            applyResult = result
            // Keep the field on the attempted value (with its warning) when the
            // port is in use; otherwise let it track the persisted value again.
            if case .portInUse = result {} else { editedPort = nil }
            isApplying = false
        }
    }

    /// Status under the port row: an out-of-range hint, the most recent Apply
    /// result for the cases the live indicator can't convey, or the live
    /// bound-port indicator otherwise.
    @ViewBuilder
    private var boundPortStatusRow: some View {
        if !isDraftValid {
            statusCaption {
                Label(
                    String(localized: "settings.mobile.port.status.invalid", defaultValue: "Port must be between 1 and 65535."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        } else if case let .portInUse(requested) = applyResult, iOSPairingHost.current {
            // Only while pairing is on — toggling off stops the listener, which
            // would make "still listening on …" wrong.
            statusCaption {
                Label(
                    String(
                        localized: "settings.mobile.port.apply.inUse",
                        defaultValue: "Port \(requested) is in use. Still listening on \(status.current?.boundPort ?? requested)."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        } else if case let .savedForLater(saved) = applyResult, !iOSPairingHost.current {
            // Only while pairing is off — once it's on, the live indicator shows
            // the actual listening port instead of this saved-for-later note.
            statusCaption {
                Label(
                    String(localized: "settings.mobile.port.apply.saved", defaultValue: "Saved. Will use port \(saved) when iOS Pairing is on."),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.secondary)
            }
        } else if iOSPairingHost.current, let snapshot = status.current {
            statusCaption { boundPortStatusText(snapshot) }
        }
    }

    @ViewBuilder
    private func statusCaption(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .cmuxFont(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func boundPortStatusText(_ snapshot: MobilePairingStatusSnapshot) -> some View {
        if !snapshot.isRunning {
            Text(String(localized: "settings.mobile.port.status.starting", defaultValue: "Starting the pairing listener…"))
                .foregroundStyle(.secondary)
        } else if snapshot.usesEphemeralFallback, let bound = snapshot.boundPort {
            Label(
                String(
                    localized: "settings.mobile.port.status.fallback",
                    defaultValue: "Port \(snapshot.configuredPort) is in use. Listening on \(bound) instead."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        } else if let bound = snapshot.boundPort {
            Label(
                String(localized: "settings.mobile.port.status.ok", defaultValue: "Listening on port \(bound)."),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var displayNameRow: some View {
        // Show this Mac's system name as the placeholder so the user sees the
        // actual default that applies when the override is empty.
        let resolvedName = hostActions.mobilePairingDefaultDisplayName()
        let placeholder = resolvedName.isEmpty
            ? String(localized: "settings.mobile.displayName.placeholder", defaultValue: "This Mac's name")
            : resolvedName
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:iOSPairingDisplayName",
            String(localized: "settings.mobile.displayName", defaultValue: "Display Name"),
            subtitle: String(localized: "settings.mobile.displayName.subtitle", defaultValue: "Name the iOS app shows for this Mac when pairing. Empty uses this Mac's name."),
            controlWidth: Self.columnWidth
        ) {
            TextField(
                placeholder,
                text: Binding(get: { displayName.current }, set: { displayName.set($0) })
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("SettingsMobilePairingDisplayNameField")
        }
    }

    @ViewBuilder
    private var artifactFolderAccessRow: some View {
        SettingsCardRow(
            configurationReview: .json("mobile.artifactFolderAccess"),
            String(localized: "settings.mobile.artifactFolderAccess", defaultValue: "Folder Access"),
            subtitle: artifactFolderAccessSubtitle
        ) {
            Picker(
                "",
                selection: Binding(
                    get: { artifactFolderAccess.current },
                    set: { artifactFolderAccess.set($0) }
                )
            ) {
                Text(String(
                    localized: "settings.mobile.artifactFolderAccess.subtree",
                    defaultValue: "Entire Subtree"
                ))
                .tag(MobileArtifactFolderAccess.subtree)
                Text(String(
                    localized: "settings.mobile.artifactFolderAccess.oneLevel",
                    defaultValue: "One Level"
                ))
                .tag(MobileArtifactFolderAccess.oneLevel)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsMobileArtifactFolderAccessPicker")
        }
    }

    private var artifactFolderAccessSubtitle: String {
        switch artifactFolderAccess.current {
        case .subtree:
            String(
                localized: "settings.mobile.artifactFolderAccess.subtitleSubtree",
                defaultValue: "Lets iOS browse any item inside a folder referenced by chat or visible in a terminal."
            )
        case .oneLevel:
            String(
                localized: "settings.mobile.artifactFolderAccess.subtitleOneLevel",
                defaultValue: "Limits iOS to immediate children of referenced or visible folders."
            )
        }
    }

    /// Read-only connection count and the reachable routes the phone can use.
    @ViewBuilder
    private var diagnostics: some View {
        let snapshot = status.current
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:connections",
            String(localized: "settings.mobile.connections", defaultValue: "Connected Devices"),
            subtitle: String(localized: "settings.mobile.connections.subtitle", defaultValue: "iOS devices currently attached to this Mac.")
        ) {
            Text("\(snapshot?.activeConnectionCount ?? 0)")
                .cmuxFont(size: 13, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        routesView(snapshot)
    }

    @ViewBuilder
    private func routesView(_ snapshot: MobilePairingStatusSnapshot?) -> some View {
        if let snapshot, snapshot.isRunning {
            if snapshot.routes.isEmpty {
                SettingsCardNote(String(
                    localized: "settings.mobile.routes.empty",
                    defaultValue: "No reachable addresses yet. Pairing over the network needs Tailscale running on this Mac."
                ))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    routesHeader(snapshot.routes)
                    ForEach(snapshot.routes) { route in
                        routeRow(route)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                // Verify on display and whenever the advertised set changes.
                // Keyed on the endpoints, not the snapshot, so the connection
                // count ticking does not re-dial the listener — and there is no
                // timer anywhere in this path.
                .task(id: Self.routeIdentity(snapshot.routes)) {
                    await verifyRoutes(snapshot.routes)
                }
            }
        }
    }

    @ViewBuilder
    private func routesHeader(_ routes: [MobilePairingRoute]) -> some View {
        HStack(spacing: 6) {
            Text(String(localized: "settings.mobile.routes.title", defaultValue: "Reachable at"))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await verifyRoutes(routes) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isVerifyingRoutes)
            .help(String(
                localized: "settings.mobile.routes.recheck",
                defaultValue: "Check these addresses again"
            ))
            .accessibilityIdentifier("SettingsMobileRouteRecheckButton")
        }
    }

    @ViewBuilder
    private func routeRow(_ route: MobilePairingRoute) -> some View {
        let state = routeReachability[route.id] ?? .unverified
        // Two lines: the address keeps the full width it needs (a tailnet ULA
        // literal is long), and the verdict sits under it rather than competing
        // with it for the same row.
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(route.kindLabel)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(route.endpoint)
                    .cmuxFont(.caption, design: .monospaced)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            Label(state.settingsStatusText, systemImage: state.settingsStatusSystemImage)
                .cmuxFont(.caption)
                .foregroundStyle(
                    state.settingsStatusIsWarning
                        ? AnyShapeStyle(Color.orange)
                        : AnyShapeStyle(HierarchicalShapeStyle.secondary)
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("SettingsMobileRouteStatus.\(route.id)")
        }
        .padding(.bottom, 2)
    }

    /// Runs one verification pass and applies the result.
    ///
    /// Routes with no result yet stay ``CmxRouteReachability/unverified`` rather
    /// than inheriting a stale verdict, and a host that reports nothing clears
    /// the map — a failed check downgrades the display and never tears anything
    /// down. `await` keeps the dialing off the main actor; the button and the
    /// rest of the pane stay live.
    private func verifyRoutes(_ routes: [MobilePairingRoute]) async {
        guard !routes.isEmpty else {
            routeReachability = [:]
            return
        }
        guard !isVerifyingRoutes else { return }
        isVerifyingRoutes = true
        defer { isVerifyingRoutes = false }
        // Drop the previous verdicts before dialing: while a pass is running
        // every row genuinely is unverified again, and keeping last pass's
        // answer on screen would turn it back into a claim.
        routeReachability = [:]
        routeReachability = await hostActions.verifyMobilePairingRouteReachability()
    }

    /// Identity for the verification task: the exact endpoints being claimed.
    /// A changed port or address restarts the check; a changed connection count
    /// does not.
    private static func routeIdentity(_ routes: [MobilePairingRoute]) -> String {
        routes.map { "\($0.id)@\($0.endpoint)" }.joined(separator: ",")
    }
}
