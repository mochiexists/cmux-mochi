import CMUXMobileCore
public import CmuxMobileRPC

/// The outcome of removing one paired computer from the iPhone.
public enum MobileComputerRemovalResult: Sendable, Equatable {
    /// The Mac revoked this iPhone and the iPhone removed its local pairing.
    case removed
    /// The Mac could not be reached, so removing only the iPhone-side pairing
    /// requires an explicit second confirmation.
    case requiresLocalOnlyConfirmation
    /// Local persistence could not be updated after authority was revoked.
    case failed
}

/// Destroys the iPhone-side DeviceLink credential for one paired Mac.
public protocol MobileDeviceLinkCredentialRemoving: Sendable {
    /// Returns whether a usable key and server pin exist for the exact app instance.
    func hasUsableCredential(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) -> Bool

    /// Removes the exact app instance's index, device identity, and server pin.
    @discardableResult
    func forgetPairing(macDeviceID: String, instanceTag: String?) -> String?
}

extension MobileDeviceLinkClient: MobileDeviceLinkCredentialRemoving {}

/// Sends the authenticated DeviceLink self-revocation request to a live Mac.
public protocol MobileDeviceLinkSelfRevocationSending: Sendable {
    /// Revokes the fingerprint proven by `client`'s mutual-TLS connection.
    func revokeSelf(using client: MobileCoreRPCClient) async throws
}

/// Production DeviceLink self-revocation RPC sender.
public struct MobileDeviceLinkSelfRevocationSender: MobileDeviceLinkSelfRevocationSending {
    /// Creates an RPC sender.
    public init() {}

    public func revokeSelf(using client: MobileCoreRPCClient) async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.pairing.device.revoke_self",
            params: [:]
        )
        _ = try await client.sendRequest(request)
    }
}
