#if DEBUG
import DeviceLinkKit
import Foundation

/// File-backed DeviceLink state used only by the explicit end-to-end harness.
///
/// Headless self-hosted runners keep the login keychain locked. The production
/// store must fail loudly in that state, while the E2E harness still needs a
/// durable identity and authorization table across its deliberate host restart.
/// This store is selected only when `CMUX_E2E_DEVICELINK_STATE_DIR` is present
/// in a DEBUG process; normal app launches continue to use the keychain.
struct MobileHostDeviceLinkE2EStateStore: AuthorizedDeviceStoring {
    private struct StoredIdentity: Codable {
        let pemPrivateKey: String
        let derEncodedCertificate: Data
    }

    private let directoryURL: URL
    private let authorizedDevicesURL: URL
    private let identityURL: URL

    init(directoryURL: URL) throws {
        let standardizedURL = directoryURL.standardizedFileURL
        guard standardizedURL.isFileURL,
              standardizedURL.path != "/",
              standardizedURL.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        self.directoryURL = standardizedURL
        self.authorizedDevicesURL = standardizedURL.appendingPathComponent("authorized-devices.json")
        self.identityURL = standardizedURL.appendingPathComponent("host-identity.json")
        try prepareDirectory()
    }

    func load() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: authorizedDevicesURL.path) else {
            return nil
        }
        return try Data(contentsOf: authorizedDevicesURL)
    }

    func save(_ data: Data) async throws {
        try prepareDirectory()
        try data.write(to: authorizedDevicesURL, options: .atomic)
        try restrictPermissions(at: authorizedDevicesURL, permissions: 0o600)
    }

    func loadOrCreateIdentityMaterial() throws -> DeviceIdentityMaterial {
        if FileManager.default.fileExists(atPath: identityURL.path) {
            let stored = try JSONDecoder().decode(
                StoredIdentity.self,
                from: Data(contentsOf: identityURL)
            )
            return try DeviceIdentityMaterial(
                pemPrivateKey: stored.pemPrivateKey,
                derEncodedCertificate: stored.derEncodedCertificate
            )
        }

        let material = try DeviceIdentityMaterial.generate(commonName: "cmux-mac-e2e")
        let stored = StoredIdentity(
            pemPrivateKey: material.pemPrivateKey,
            derEncodedCertificate: material.derEncodedCertificate
        )
        try prepareDirectory()
        try JSONEncoder().encode(stored).write(to: identityURL, options: .atomic)
        try restrictPermissions(at: identityURL, permissions: 0o600)
        return material
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try restrictPermissions(at: directoryURL, permissions: 0o700)
    }

    private func restrictPermissions(at url: URL, permissions: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}
#endif
