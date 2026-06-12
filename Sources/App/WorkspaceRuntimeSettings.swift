import Darwin
import Foundation

enum WorkspaceTitlebarSettings {
    static let showTitlebarKey = "workspaceTitlebarVisible"
    static let defaultShowTitlebar = true

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showTitlebarKey) == nil {
            return defaultShowTitlebar
        }
        return defaults.bool(forKey: showTitlebarKey)
    }
}
enum WorkspacePresentationModeSettings {
    static let modeKey = "workspacePresentationMode"

    enum Mode: String {
        case standard
        case minimal
    }

    static let defaultMode: Mode = .standard

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func mode(defaults: UserDefaults = .standard) -> Mode {
        mode(for: defaults.string(forKey: modeKey))
    }

    static func isMinimal(defaults: UserDefaults = .standard) -> Bool {
        mode(defaults: defaults) == .minimal
    }
}

enum WorkspaceButtonFadeSettings {
    static let modeKey = "workspaceButtonsFadeMode"
    static let legacyTitlebarControlsVisibilityModeKey = "titlebarControlsVisibilityMode"
    static let legacyPaneTabBarControlsVisibilityModeKey = "paneTabBarControlsVisibilityMode"

    enum Mode: String {
        case enabled
        case disabled
    }

    static let defaultMode: Mode = .disabled

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        mode(for: defaults.string(forKey: modeKey)) == .enabled
    }

    static func initializeStoredModeIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: modeKey) == nil else { return }

        if let migratedMode = migratedLegacyMode(defaults: defaults) {
            defaults.set(migratedMode.rawValue, forKey: modeKey)
            return
        }

        let initialMode: Mode = WorkspaceTitlebarSettings.isVisible(defaults: defaults) ? .disabled : .enabled
        defaults.set(initialMode.rawValue, forKey: modeKey)
    }

    private static func migratedLegacyMode(defaults: UserDefaults) -> Mode? {
        let legacyValues = [
            defaults.string(forKey: legacyTitlebarControlsVisibilityModeKey),
            defaults.string(forKey: legacyPaneTabBarControlsVisibilityModeKey),
        ]

        if legacyValues.contains(where: { $0 == "onHover" || $0 == "hover" || $0 == "enabled" }) {
            return .enabled
        }
        if legacyValues.contains(where: { $0 == "always" || $0 == "disabled" }) {
            return .disabled
        }
        return nil
    }
}

enum PaneFirstClickFocusSettings {
    static let enabledKey = "paneFirstClickFocus.enabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

enum TerminalScrollBarSettings {
    static let showScrollBarKey = "terminal.showScrollBar"
    static let defaultShowScrollBar = true
    static let didChangeNotification = Notification.Name("cmux.terminalScrollBarSettingsDidChange")

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showScrollBarKey) == nil {
            return defaultShowScrollBar
        }
        return defaults.bool(forKey: showScrollBarKey)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum TerminalScrollbackAutosaveSettings {
    static let enabledKey = "terminal.autosaveScrollback"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

/// How restored agent terminals behave when cmux Mochi reopens after a quit.
/// Off:    no scrollback replay, no resume command prefill (fresh terminal).
/// medium: replay scrollback and prefill the resume command without submitting it.
/// full:   immediately run the resume command (no scrollback replay).
enum AgentSessionResumeMode: String, CaseIterable, Identifiable {
    case off
    case medium
    case full

    var id: String { rawValue }

    /// Replay the previous terminal scrollback for agent terminals on restore.
    var replaysScrollback: Bool { self == .medium }

    /// Prefill the resume command into the terminal input on restore.
    var prefillsResumeCommand: Bool { self == .medium || self == .full }

    /// Submit (auto-run) the prefilled resume command on restore.
    var submitsResumeCommand: Bool { self == .full }

    var displayName: String {
        switch self {
        case .off:
            return String(localized: "settings.terminal.agentResumeMode.off", defaultValue: "Off")
        case .medium:
            return String(localized: "settings.terminal.agentResumeMode.medium", defaultValue: "Medium")
        case .full:
            return String(localized: "settings.terminal.agentResumeMode.full", defaultValue: "Full")
        }
    }

    var settingsSubtitle: String {
        switch self {
        case .off:
            return String(
                localized: "settings.terminal.agentResumeMode.off.subtitle",
                defaultValue: "Restored agent terminals start fresh — no scrollback and no resume command."
            )
        case .medium:
            return String(
                localized: "settings.terminal.agentResumeMode.medium.subtitle",
                defaultValue: "Restored agent terminals show their previous scrollback and leave the resume command ready to run."
            )
        case .full:
            return String(
                localized: "settings.terminal.agentResumeMode.full.subtitle",
                defaultValue: "Restored agent terminals immediately run their resume command."
            )
        }
    }
}

enum AgentSessionAutoResumeSettings {
    /// Current tri-state key. Stores an `AgentSessionResumeMode` raw value.
    static let modeKey = "terminal.agentResumeMode"
    /// Legacy boolean key (true == full, false == medium). Read for migration only.
    static let legacyAutoResumeAgentSessionsKey = "terminal.autoResumeAgentSessions"
    static let defaultMode: AgentSessionResumeMode = .medium
    static let didChangeNotification = Notification.Name("cmux.agentSessionAutoResumeSettingsDidChange")

    static func mode(defaults: UserDefaults = .standard) -> AgentSessionResumeMode {
        if let raw = defaults.string(forKey: modeKey),
           let mode = AgentSessionResumeMode(rawValue: raw) {
            return mode
        }
        // Migrate the legacy boolean: auto-resume on -> full, off -> medium.
        if defaults.object(forKey: legacyAutoResumeAgentSessionsKey) != nil {
            return defaults.bool(forKey: legacyAutoResumeAgentSessionsKey) ? .full : .medium
        }
        return defaultMode
    }

    /// Convenience for the App Storage default so the Settings picker reflects a
    /// migrated legacy value on first launch.
    static var defaultModeRawValueForStorage: String {
        mode().rawValue
    }

    static func setMode(
        _ mode: AgentSessionResumeMode,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let previous = self.mode(defaults: defaults)
        defaults.set(mode.rawValue, forKey: modeKey)
        if previous != mode {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let previous = mode(defaults: defaults)
        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: legacyAutoResumeAgentSessionsKey)
        let didChange = previous != mode(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

/// Selects the shell command form used when resuming an agent session.
///
/// `alias` emits the short, baked-in fork aliases (`cx`/`cxy`/`cc`/`ccy resume <id>`),
/// which the cmux shell integration always defines in a cmux-spawned terminal. It is
/// short and readable but relies on the provider session id to re-attach context.
/// `verbose` emits the full absolute-path + env + preserved-flags form, which carries
/// the original `--model`/`--add-dir`/env across the resume. Both forms `cd` into the
/// recorded working directory first.
enum AgentResumeCommandStyle: String, CaseIterable, Identifiable, Sendable {
    case alias
    case verbose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alias:
            return String(localized: "settings.terminal.agentResumeStyle.alias", defaultValue: "Short alias")
        case .verbose:
            return String(localized: "settings.terminal.agentResumeStyle.verbose", defaultValue: "Full command")
        }
    }

    var settingsSubtitle: String {
        switch self {
        case .alias:
            return String(
                localized: "settings.terminal.agentResumeStyle.alias.subtitle",
                defaultValue: "Resume with the short fork alias (e.g. `cxy resume <id>`). Relies on the session id to re-attach."
            )
        case .verbose:
            return String(
                localized: "settings.terminal.agentResumeStyle.verbose.subtitle",
                defaultValue: "Resume with the full command, preserving the original model, --add-dir, and environment flags."
            )
        }
    }
}

enum AgentResumeCommandStyleSettings {
    static let styleKey = "terminal.agentResumeCommandStyle"
    static let defaultStyle: AgentResumeCommandStyle = .alias
    static let didChangeNotification = Notification.Name("cmux.agentResumeCommandStyleDidChange")

    static func style(defaults: UserDefaults = .standard) -> AgentResumeCommandStyle {
        if let raw = defaults.string(forKey: styleKey),
           let style = AgentResumeCommandStyle(rawValue: raw) {
            return style
        }
        return defaultStyle
    }

    static var defaultStyleRawValueForStorage: String {
        style().rawValue
    }

    static func setStyle(
        _ style: AgentResumeCommandStyle,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let previous = self.style(defaults: defaults)
        defaults.set(style.rawValue, forKey: styleKey)
        if previous != style {
            notificationCenter.post(name: didChangeNotification, object: nil)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let previous = style(defaults: defaults)
        defaults.removeObject(forKey: styleKey)
        let didChange = previous != style(defaults: defaults)
        if didChange {
            notificationCenter.post(name: didChangeNotification, object: nil)
        }
        return didChange
    }
}

enum RightSidebarBetaFeatureSettings {
    static let dockEnabledKey = "rightSidebar.beta.dock.enabled"

    static let defaultDockEnabled = false

    nonisolated static func isDockEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: dockEnabledKey) != nil else { return defaultDockEnabled }
        return defaults.bool(forKey: dockEnabledKey)
    }
}

enum UITestLaunchManifest {
    static let argumentName = "-cmuxUITestLaunchManifest"

    struct Payload: Decodable {
        let environment: [String: String]
    }

    static func applyIfPresent(
        arguments: [String] = CommandLine.arguments,
        loadData: (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        },
        applyEnvironment: (String, String) -> Void = { key, value in
            setenv(key, value, 1)
        }
    ) {
        guard let path = manifestPath(from: arguments),
              let data = loadData(path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }

        for (key, value) in payload.environment {
            applyEnvironment(key, value)
        }
    }

    static func manifestPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argumentName) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }

        let rawPath = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return rawPath.isEmpty ? nil : rawPath
    }
}
