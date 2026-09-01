import Foundation
import Testing
@testable import CmuxHive

@MainActor
@Suite("Hive composition")
struct HiveCompositionTests {
    @Test("builds an account-free DeviceLink workspace owner")
    func buildsCoordinator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("hive.sqlite3")
        let defaults = try #require(
            UserDefaults(suiteName: "HiveCompositionTests-\(UUID().uuidString)")
        )

        let composition = try HiveComposition(
            databaseURL: databaseURL,
            defaults: defaults
        )

        #expect(composition.coordinator.phase == .idle)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
    }
}
