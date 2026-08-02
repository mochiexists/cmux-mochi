public import Foundation
internal import Security

/// Errors from the keychain-backed stores.
public enum KeychainStorageError: Error, Equatable {
    /// The item exists but the keychain is locked. **Not** the same as absent:
    /// a caller must never respond to this by generating a replacement
    /// identity, which would silently orphan every pairing this device holds.
    case locked
    /// Any other `OSStatus` failure, carried for diagnosis.
    case unexpectedStatus(OSStatus)
}

/// Namespacing for keychain items.
///
/// A physical Mac runs Stable, Nightly, and tagged development builds at once;
/// they must never read each other's identities or authorized-devices tables,
/// or revoking a phone in one build would appear to do nothing in another.
/// Service strings therefore carry the bundle identifier *and* the instance
/// tag.
public struct KeychainScope: Sendable, Equatable {
    public let bundleIdentifier: String
    public let instanceTag: String?

    public init(bundleIdentifier: String, instanceTag: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.instanceTag = instanceTag
    }

    /// Service string for a given item kind.
    public func service(for kind: String) -> String {
        var parts = ["dev.cmux.devicelink", kind, bundleIdentifier]
        if let instanceTag, !instanceTag.isEmpty { parts.append(instanceTag) }
        return parts.joined(separator: ".")
    }
}

/// Generic-password storage with DeviceLink's accessibility policy.
///
/// Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// - *AfterFirstUnlock* so a backgrounded relaunch can reconnect without the
///   user unlocking first.
/// - *ThisDeviceOnly* because a device identity must not travel — note that
///   `kSecAttrSynchronizable = false` alone still permits migration via an
///   encrypted backup, which would clone a device's identity onto another
///   device.
struct KeychainItem {
    let service: String
    let account: String

    /// macOS has two keychains; the data-protection one requires an
    /// `application-identifier` entitlement that a locally signed development
    /// build does not carry, so it answers `errSecMissingEntitlement` (-34018).
    /// Every operation therefore tries data protection first and falls back to
    /// the file keychain on macOS only: a properly provisioned build never
    /// reaches the fallback, and iOS has no second keychain to fall back to.
    private func baseQuery(dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        query[kSecUseDataProtectionKeychain] = dataProtection
        return query
    }

    /// Runs `attempt` against the data-protection keychain, retrying on the
    /// file keychain when the platform refuses for lack of entitlement.
    private func withKeychainFallback<T>(
        _ attempt: (Bool) throws -> T?
    ) throws -> T? {
        do {
            return try attempt(true)
        } catch KeychainStorageError.unexpectedStatus(let status)
            where status == errSecMissingEntitlement || status == errSecNotAvailable
        {
            #if os(iOS)
            throw KeychainStorageError.unexpectedStatus(status)
            #else
            return try attempt(false)
            #endif
        }
    }

    func read() throws -> Data? {
        try withKeychainFallback { dataProtection in
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                return result as? Data
            case errSecItemNotFound:
                return nil
            case errSecInteractionNotAllowed:
                throw KeychainStorageError.locked
            default:
                throw KeychainStorageError.unexpectedStatus(status)
            }
        }
    }

    func write(_ data: Data) throws {
        _ = try withKeychainFallback { dataProtection -> Bool? in
            let query = baseQuery(dataProtection: dataProtection)
            let attributes: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]

            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            switch updateStatus {
            case errSecSuccess:
                return true
            case errSecItemNotFound:
                var insert = query
                insert[kSecValueData] = data
                insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let addStatus = SecItemAdd(insert as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw KeychainStorageError.unexpectedStatus(addStatus)
                }
                return true
            case errSecInteractionNotAllowed:
                throw KeychainStorageError.locked
            default:
                throw KeychainStorageError.unexpectedStatus(updateStatus)
            }
        }
    }

    func delete() throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            if status == errSecSuccess { return }
            if status != errSecItemNotFound, status != errSecMissingEntitlement {
                throw KeychainStorageError.unexpectedStatus(status)
            }
            #if os(iOS)
            return
            #endif
        }
    }
}

/// Keychain-backed persistence for the Mac's authorized-devices table.
public struct KeychainAuthorizedDeviceStore: AuthorizedDeviceStoring {
    private let item: KeychainItem

    /// - Parameter scope: Bundle/instance namespacing (see ``KeychainScope``).
    public init(scope: KeychainScope) {
        item = KeychainItem(service: scope.service(for: "devices"), account: "authorized-devices")
    }

    public func load() async throws -> Data? {
        try item.read()
    }

    public func save(_ data: Data) async throws {
        try item.write(data)
    }
}

/// Keychain-backed storage for this device's own identities.
///
/// The phone keeps **one identity per paired Mac** rather than a single global
/// key: theft of one key then exposes exactly one pairing, and the same
/// fingerprint never appears across two Macs, so pairings cannot be correlated
/// by an observer who sees both.
public struct KeychainDeviceIdentityStore: Sendable {
    private let scope: KeychainScope

    public init(scope: KeychainScope) {
        self.scope = scope
    }

    /// Loads the identity for a pairing, if one has been generated.
    /// - Parameter pairingID: Stable identity of the peer this key is for.
    /// - Throws: ``KeychainStorageError/locked`` when the keychain is not yet
    ///   available — callers must treat that as "try later", never as "absent".
    public func identity(forPairingID pairingID: String) throws -> DeviceIdentityMaterial? {
        guard let data = try item(pairingID).read() else { return nil }
        let decoder = JSONDecoder()
        guard let stored = try? decoder.decode(StoredIdentity.self, from: data) else { return nil }
        return try DeviceIdentityMaterial(
            pemPrivateKey: stored.pemPrivateKey,
            derEncodedCertificate: stored.derEncodedCertificate
        )
    }

    /// Persists identity material for a pairing.
    public func save(_ material: DeviceIdentityMaterial, forPairingID pairingID: String) throws {
        let stored = StoredIdentity(
            pemPrivateKey: material.pemPrivateKey,
            derEncodedCertificate: material.derEncodedCertificate
        )
        try item(pairingID).write(try JSONEncoder().encode(stored))
    }

    /// Removes a pairing's identity — used when the user forgets a Mac.
    public func remove(pairingID: String) throws {
        try item(pairingID).delete()
    }

    private func item(_ pairingID: String) -> KeychainItem {
        KeychainItem(service: scope.service(for: "identity"), account: pairingID)
    }

    private struct StoredIdentity: Codable {
        let pemPrivateKey: String
        let derEncodedCertificate: Data
    }
}

/// Keychain-backed storage for the pins a phone holds for its paired Macs.
public struct KeychainServerPinStore: Sendable {
    private let item: KeychainItem

    public init(scope: KeychainScope) {
        item = KeychainItem(service: scope.service(for: "pins"), account: "server-pins")
    }

    /// All stored pins, keyed by pairing identity.
    public func pins() throws -> [String: DeviceFingerprint] {
        guard let data = try item.read(),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return raw.compactMapValues(DeviceFingerprint.init(hex:))
    }

    /// Stores or replaces the pin for a pairing.
    public func setPin(_ fingerprint: DeviceFingerprint, forPairingID pairingID: String) throws {
        var current = (try? pins()) ?? [:]
        current[pairingID] = fingerprint
        try persist(current)
    }

    /// Removes a pairing's pin.
    public func removePin(forPairingID pairingID: String) throws {
        var current = (try? pins()) ?? [:]
        current[pairingID] = nil
        try persist(current)
    }

    private func persist(_ pins: [String: DeviceFingerprint]) throws {
        let raw = pins.mapValues(\.hex)
        try item.write(try JSONEncoder().encode(raw))
    }
}
