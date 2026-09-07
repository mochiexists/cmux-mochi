public import CmuxMobileShell
import CmuxMobilePairedMac
import CmuxMobileShellModel
public import Foundation

/// Account-free macOS composition root for the DeviceLink Hive.
@MainActor
public final class HiveComposition {
    public let coordinator: HiveWorkspaceCoordinator
    public let shell: MobileShellComposite

    /// Creates a Hive owner with a dedicated local pairing database.
    public init(
        databaseURL: URL,
        defaults: UserDefaults = .standard,
        allowsLoopbackRoutes: Bool = false
    ) throws {
        let pairedMacStore = try MobilePairedMacStore(databaseURL: databaseURL)
        let runtime = HiveMobileRuntime.network(
            allowsLoopbackRoutes: allowsLoopbackRoutes
        ) { request in
            let options = MobileDeviceLinkClient.shared.pairingTLSOptions(
                forMacDeviceID: request.expectedPeerDeviceID,
                instanceTag: request.expectedPeerInstanceTag
            )
            MobileDeviceLinkClient.reportTLSOptionsLookup(
                succeeded: options != nil
            )
            return options
        }
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: false,
            pairedMacStore: pairedMacStore,
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
        self.shell = shell
        coordinator = HiveWorkspaceCoordinator(shell: shell)
    }

    /// Creates the production owner at Hive's default database location.
    public convenience init(
        defaults: UserDefaults = .standard,
        allowsLoopbackRoutes: Bool = false
    ) throws {
        try self.init(
            databaseURL: Self.defaultDatabaseURL(),
            defaults: defaults,
            allowsLoopbackRoutes: allowsLoopbackRoutes
        )
    }

    /// The Hive pairing database is separate from the iPhone-shell database.
    public static func defaultDatabaseURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent(
            "cmux",
            isDirectory: true
        )
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory.appendingPathComponent(
            "hive-paired-computers.sqlite3"
        )
    }
}
