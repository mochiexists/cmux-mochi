import Foundation

/// Mobile integration settings for pairing and syncing with cmux on iOS.
public struct MobileCatalogSection: SettingCatalogSection {
    /// Folder paths that iOS may access after a chat or terminal references a directory.
    public let artifactFolderAccess = DefaultsKey<MobileArtifactFolderAccess>(
        id: "mobile.artifactFolderAccess",
        defaultValue: .subtree,
        userDefaultsKey: "mobile.artifactFolderAccess"
    )

    /// Mac-side iOS pairing host. Release defaults OFF so macOS never asks for
    /// Local Network permission until the user opts in from Settings. DEBUG
    /// (dev) builds default ON so a dev Mac advertises its attach route without a
    /// manual Settings toggle — this is what lets a fresh dev iOS build discover
    /// the Mac automatically (see MacPairedMacBackupPublisher). An explicit user
    /// toggle still wins on either build.
    public let iOSPairingHost = DefaultsKey<Bool>(
        id: "mobile.iOSPairingHost.enabled",
        defaultValue: Self.iOSPairingHostDefault,
        userDefaultsKey: "mobile.iOSPairingHost.enabled"
    )

    #if DEBUG
    private static let iOSPairingHostDefault = true
    #else
    private static let iOSPairingHostDefault = false
    #endif

    /// TCP port the Mac-side iOS pairing listener binds.
    ///
    /// This is a *fixed service port*, not a preference: if it is already in use
    /// the listener refuses to start and reports why, rather than moving to an
    /// OS-assigned port. A paired phone stores the `host:port` it was handed, so
    /// a host that silently moved would be running at an address no phone has
    /// ever been told about — indistinguishable, from the phone, from a Mac that
    /// is switched off. Changing this port requires re-pairing.
    ///
    /// The default mirrors `CmxMobileDefaults.channelHostPort` (kept in step by
    /// `MobileCatalogSectionTests`; this package deliberately does not depend on
    /// CMUXMobileCore), so a debug build and the installed release build can run
    /// side by side instead of fighting over one fixed port.
    public let iOSPairingPort = DefaultsKey<Int>(
        id: "mobile.iOSPairingHost.port",
        defaultValue: Self.channelPairingPort,
        userDefaultsKey: "mobile.iOSPairingHost.port"
    )

    /// Mirrors `CmxMobileDefaults.channelHostPort(launchTag:)`.
    ///
    /// Tagged dev builds derive their port from the tag so several can run at
    /// once; the listener fails closed, so a single shared debug port would let
    /// only the first build host pairing. The mapping is a pure function of the
    /// tag, so a given tag binds the same port on every launch.
    static var channelPairingPort: Int {
        #if DEBUG
        let tag = ProcessInfo.processInfo.environment["CMUX_TAG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !tag.isEmpty else { return 58_467 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in tag.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return 58_467 + Int(hash % 64)
        #else
        return 58_465
        #endif
    }

    /// Optional override for the name the iOS app shows for this Mac during
    /// pairing. Empty means use the Mac's name from System Settings
    /// (`Host.current().localizedName`). Useful when pairing against several
    /// Macs that would otherwise share a name.
    public let iOSPairingDisplayName = DefaultsKey<String>(
        id: "mobile.iOSPairingHost.displayName",
        defaultValue: "",
        userDefaultsKey: "mobile.iOSPairingHost.displayName"
    )

    /// Creates the Mobile settings catalog section.
    public init() {}
}
