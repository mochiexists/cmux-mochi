import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import DeviceLinkKit
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite("Shared computer removal")
struct MobileComputerRemovalTests {
    @MainActor
    @Test("an unreachable Mac requires confirmation and preserves every local authority")
    func offlineRemovalRequiresConfirmation() async throws {
        let sender = RecordingSelfRevocationSender(outcome: .failure)
        let fixture = try await makeFixture(
            label: "offline",
            deviceLinkSelfRevocationSender: sender
        )
        defer { fixture.cleanup() }
        _ = try fixture.seedCredential(instanceTag: "nightly", byte: 0x11)
        try fixture.installLiveClient()

        let result = await fixture.composite.removeComputer(
            representativeID: fixture.targetID,
            aliasIDs: [fixture.targetMac]
        )

        #expect(result == .requiresLocalOnlyConfirmation)
        #expect(await sender.callCount == 1)
        #expect(fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "nightly"
        ))
        let rows = try await fixture.store.loadAll(
            stackUserID: fixture.scopeID,
            teamID: nil
        )
        #expect(rows.map(\.macDeviceID).contains(fixture.targetMac))
        #expect(rows.map(\.macDeviceID).contains(fixture.otherMac))
    }

    @MainActor
    @Test("successful DeviceLink revoke removes exact Nightly pairing and keeps Stable")
    func successfulDeviceLinkRemovalIsComposedAndInstanceScoped() async throws {
        let sender = RecordingSelfRevocationSender(outcome: .success)
        let fixture = try await makeFixture(
            label: "success",
            deviceLinkSelfRevocationSender: sender
        )
        defer { fixture.cleanup() }
        let nightlyPairingID = try fixture.seedCredential(instanceTag: "nightly", byte: 0x22)
        let stablePairingID = try fixture.seedCredential(instanceTag: "stable", byte: 0x33)
        try fixture.installLiveClient()

        let result = await fixture.composite.removeComputer(
            representativeID: fixture.targetID,
            aliasIDs: [fixture.targetMac]
        )

        #expect(result == .removed)
        #expect(await sender.callCount == 1)
        #expect(!fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "nightly"
        ))
        #expect(fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "stable"
        ))
        #expect(fixture.credentials.pin(forPairingID: nightlyPairingID) == nil)
        #expect(fixture.credentials.pin(forPairingID: stablePairingID) != nil)
        let rows = try await fixture.store.loadAll(stackUserID: fixture.scopeID, teamID: nil)
        #expect(!rows.map(\.id).contains(fixture.targetID))
        #expect(rows.map(\.id).contains(fixture.stableID))
    }

    @MainActor
    @Test("merged aliases use the selected instance as revoke authority")
    func mergedAliasesUseExactRepresentativeAndExcludeSiblingBuilds() async throws {
        let sender = RecordingSelfRevocationSender(outcome: .success)
        let fixture = try await makeFixture(
            label: "representative",
            deviceLinkSelfRevocationSender: sender,
            includeAlias: true
        )
        defer { fixture.cleanup() }
        _ = try fixture.seedCredential(instanceTag: "nightly", byte: 0x24)
        _ = try fixture.seedCredential(instanceTag: "stable", byte: 0x25)
        try fixture.installLiveClient()

        let result = await fixture.composite.removeComputer(
            representativeID: fixture.targetID,
            aliasIDs: [fixture.aliasMac, fixture.stableID]
        )

        #expect(result == .removed)
        #expect(await sender.callCount == 1)
        let rows = try await fixture.store.loadAll(stackUserID: fixture.scopeID, teamID: nil)
        #expect(!rows.map(\.id).contains(fixture.targetID))
        #expect(!rows.map(\.id).contains(fixture.aliasID))
        #expect(rows.map(\.id).contains(fixture.stableID))
        #expect(fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "stable"
        ))
    }

    @MainActor
    @Test("confirmed local-only removal destroys the credential and exact row")
    func confirmedLocalRemovalClearsOnlyTheSelectedComputer() async throws {
        let fixture = try await makeFixture(label: "confirmed")
        defer { fixture.cleanup() }
        let nightlyPin = DeviceFingerprint(
            hex: String(repeating: "ab", count: 32)
        )!
        let stablePin = DeviceFingerprint(
            hex: String(repeating: "cd", count: 32)
        )!
        let nightlyPairingID = MobileDeviceLinkEnroller.pairingID(for: nightlyPin)
        let stablePairingID = MobileDeviceLinkEnroller.pairingID(for: stablePin)
        _ = try fixture.credentials.prepareIdentity(
            forPairingID: nightlyPairingID,
            macFingerprint: nightlyPin
        )
        _ = try fixture.credentials.prepareIdentity(
            forPairingID: stablePairingID,
            macFingerprint: stablePin
        )
        fixture.credentials.rememberPairing(
            macDeviceID: fixture.targetMac,
            instanceTag: "nightly",
            pairingID: nightlyPairingID
        )
        fixture.credentials.rememberPairing(
            macDeviceID: fixture.targetMac,
            instanceTag: "stable",
            pairingID: stablePairingID
        )
        #expect(fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "nightly"
        ))
        #expect(fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "stable"
        ))

        let removed = await fixture.composite.removeComputerLocally(
            representativeID: fixture.targetID,
            aliasIDs: [fixture.targetMac]
        )

        #expect(removed)
        #expect(!fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "nightly"
        ))
        #expect(fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "stable"
        ))
        #expect(fixture.credentials.pin(forPairingID: nightlyPairingID) == nil)
        #expect(fixture.credentials.pin(forPairingID: stablePairingID) != nil)
        let rows = try await fixture.store.loadAll(
            stackUserID: fixture.scopeID,
            teamID: nil
        )
        #expect(!rows.map(\.id).contains(fixture.targetID))
        #expect(rows.map(\.id).contains(fixture.stableID))
        #expect(rows.map(\.macDeviceID).contains(fixture.otherMac))
    }

    @MainActor
    @Test("an account-owned Iroh row uses broker forget instead of local-only removal")
    func accountRowPreservesBrokerForgetSemantics() async throws {
        let forget = RecordingIrohForget()
        let fixture = try await makeFixture(
            label: "account",
            ownerAccountID: "user-account",
            personalIrohForget: forget,
            includeAlias: true
        )
        defer { fixture.cleanup() }

        let result = await fixture.composite.removeComputer(
            representativeID: fixture.targetID,
            aliasIDs: [fixture.targetMac, fixture.aliasMac]
        )

        #expect(result == .removed)
        #expect(Set(forget.calls) == Set([
            IrohForgetCall(
                macDeviceID: fixture.targetMac,
                instanceTag: "nightly",
                expectedAccountID: fixture.scopeID
            ),
            IrohForgetCall(
                macDeviceID: fixture.aliasMac,
                instanceTag: "nightly",
                expectedAccountID: fixture.scopeID
            ),
        ]))
        let rows = try await fixture.store.loadAll(
            stackUserID: fixture.scopeID,
            teamID: nil
        )
        #expect(!rows.map(\.id).contains(fixture.targetID))
        #expect(!rows.map(\.id).contains(fixture.aliasID))
        #expect(rows.map(\.id).contains(fixture.stableID))
    }

    @MainActor
    @Test("removing the final pairing cancels recovery and reconnect backoff")
    func finalPairingRemovalClearsPendingReconnectState() async throws {
        let fixture = try await makeFixture(
            label: "reconnect-cleanup",
            includeSiblings: false
        )
        defer { fixture.cleanup() }
        fixture.composite.hasKnownPairedMac = true
        _ = fixture.composite.automaticReconnectBackoffOwner.recordTransientFailure(
            accountID: fixture.scopeID,
            now: Date()
        )
        let retryTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        fixture.composite.automaticReconnectRetryTask = retryTask
        fixture.composite.automaticReconnectRetryAccountID = fixture.scopeID
        let recoveryAttempt = try #require(fixture.composite.connectionRecoveryOwner.begin(
            trigger: "removal-test",
            sourceConnectionGeneration: UUID(),
            probing: false
        ))
        let recoveryTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        fixture.composite.connectionRecoveryOwner.install(recoveryTask, for: recoveryAttempt)

        let removed = await fixture.composite.removeComputerLocally(
            representativeID: fixture.targetID,
            aliasIDs: [fixture.targetMac]
        )

        #expect(removed)
        #expect(fixture.composite.connectionRecoveryOwner.phase == .idle)
        #expect(fixture.composite.automaticReconnectBackoffOwner.accountID == nil)
        #expect(fixture.composite.automaticReconnectRetryTask == nil)
        #expect(retryTask.isCancelled)
        #expect(recoveryTask.isCancelled)
        #expect(!fixture.composite.hasKnownPairedMac)
    }

    @MainActor
    @Test("failed durable row removal preserves credential for a safe retry")
    func failedRowRemovalKeepsCredential() async throws {
        let fixture = try await makeFixture(label: "row-failure", failRemoval: true)
        defer { fixture.cleanup() }
        _ = try fixture.seedCredential(instanceTag: "nightly", byte: 0x44)

        let removed = await fixture.composite.removeComputerLocally(
            representativeID: fixture.targetID,
            aliasIDs: [fixture.targetMac]
        )

        #expect(!removed)
        #expect(fixture.credentials.hasUsableCredential(
            forMacDeviceID: fixture.targetMac,
            instanceTag: "nightly"
        ))
        let rows = try await fixture.store.loadAll(stackUserID: fixture.scopeID, teamID: nil)
        #expect(rows.map(\.id).contains(fixture.targetID))
    }

    @MainActor
    private func makeFixture(
        label: String,
        ownerAccountID: String? = nil,
        personalIrohForget: (any MobileIrohMacForgetting)? = nil,
        deviceLinkSelfRevocationSender: any MobileDeviceLinkSelfRevocationSending = MobileDeviceLinkSelfRevocationSender(),
        failRemoval: Bool = false,
        includeAlias: Bool = false,
        includeSiblings: Bool = true
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let scopeID = ownerAccountID ?? MobileLocalPairingScope.identifier()
        let targetMac = "11111111-1111-1111-1111-111111111111"
        let otherMac = "22222222-2222-2222-2222-222222222222"
        let aliasMac = "33333333-3333-3333-3333-333333333333"
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 58465)
        )
        var entries = [(targetMac, "nightly", "Target Nightly")]
        if includeSiblings {
            entries.append((targetMac, "stable", "Target Stable"))
            entries.append((otherMac, "nightly", "Other"))
        }
        if includeAlias {
            // Newer insertion deliberately sorts ahead of the representative,
            // proving removal does not use rows[0] as its revoke authority.
            entries.append((aliasMac, "nightly", "Target Nightly"))
        }
        for (index, entry) in entries.enumerated() {
            try await store.upsert(
                macDeviceID: entry.0,
                displayName: entry.2,
                routes: [route],
                instanceTag: entry.1,
                markActive: false,
                stackUserID: scopeID,
                teamID: nil,
                now: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }
        let credentials = MobileDeviceLinkClient(
            scope: KeychainScope(
                bundleIdentifier: "com.cmux-mochi.tests.remove.\(label).\(UUID().uuidString)"
            )
        )
        let defaultsSuiteName = "mobile-computer-removal-\(UUID().uuidString)"
        let pairingHintDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        let pairedStore: any MobilePairedMacStoring = failRemoval
            ? RemovalFailingStore(inner: store)
            : store
        let composite = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            personalIrohForget: personalIrohForget,
            deviceLinkCredentialRemover: credentials,
            deviceLinkSelfRevocationSender: deviceLinkSelfRevocationSender,
            identityProvider: ownerAccountID.map { StaticIdentityProvider(userID: $0) },
            pairingHintDefaults: pairingHintDefaults,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        let targetID = MobilePairedMac.pairingID(
            macDeviceID: targetMac,
            instanceTag: "nightly"
        )
        let stableID = MobilePairedMac.pairingID(
            macDeviceID: targetMac,
            instanceTag: "stable"
        )
        let aliasID = MobilePairedMac.pairingID(
            macDeviceID: aliasMac,
            instanceTag: "nightly"
        )
        return Fixture(
            directory: directory,
            store: store,
            credentials: credentials,
            composite: composite,
            defaultsSuiteName: defaultsSuiteName,
            pairingHintDefaults: pairingHintDefaults,
            scopeID: scopeID,
            targetMac: targetMac,
            targetID: targetID,
            stableID: stableID,
            otherMac: otherMac,
            aliasMac: aliasMac,
            aliasID: aliasID,
            route: route
        )
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let store: MobilePairedMacStore
        let credentials: MobileDeviceLinkClient
        let composite: MobileShellComposite
        let defaultsSuiteName: String
        let pairingHintDefaults: UserDefaults
        let scopeID: String
        let targetMac: String
        let targetID: String
        let stableID: String
        let otherMac: String
        let aliasMac: String
        let aliasID: String
        let route: CmxAttachRoute

        @discardableResult
        func seedCredential(instanceTag: String, byte: UInt8) throws -> String {
            let pin = DeviceFingerprint(hex: String(repeating: String(format: "%02x", byte), count: 32))!
            let pairingID = MobileDeviceLinkEnroller.pairingID(for: pin)
            _ = try credentials.prepareIdentity(forPairingID: pairingID, macFingerprint: pin)
            credentials.rememberPairing(
                macDeviceID: targetMac,
                instanceTag: instanceTag,
                pairingID: pairingID
            )
            return pairingID
        }

        func installLiveClient() throws {
            let ticket = try CmxAttachTicket(
                workspaceID: "",
                terminalID: nil,
                macDeviceID: targetMac,
                macDisplayName: "Target Nightly",
                routes: [route],
                expiresAt: nil
            )
            composite.remoteClient = MobileCoreRPCClient(
                runtime: PairingDeadlineRuntime(),
                route: route,
                ticket: ticket,
                usesDeviceLinkIdentity: true
            )
            composite.foregroundMacDeviceID = targetMac
            composite.activeMacInstanceTag = "nightly"
            composite.connectionState = .connected
        }

        func cleanup() {
            credentials.forgetPairing(macDeviceID: targetMac, instanceTag: "nightly")
            credentials.forgetPairing(macDeviceID: targetMac, instanceTag: "stable")
            credentials.forgetPairing(macDeviceID: otherMac, instanceTag: "nightly")
            credentials.forgetPairing(macDeviceID: aliasMac, instanceTag: "nightly")
            pairingHintDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private actor RecordingSelfRevocationSender: MobileDeviceLinkSelfRevocationSending {
    enum Outcome: Equatable {
        case success
        case failure
    }

    private(set) var callCount = 0
    let outcome: Outcome

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func revokeSelf(using _: MobileCoreRPCClient) async throws {
        callCount += 1
        if outcome == .failure { throw SelfRevocationError() }
    }
}

private struct SelfRevocationError: Error {}

private struct RemovalFailingStore: MobilePairedMacStoring {
    struct RemovalError: Error {}

    let inner: any MobilePairedMacStoring

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    func upsertIfNewer(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        try await inner.upsertIfNewer(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        try await inner.upsertRoutesIfAuthorized(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            condition: condition,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        throw RemovalError()
    }

    func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        throw RemovalError()
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }

    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {
        try await inner.authorizeUserTailscaleRoutes(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID,
            routes: routes
        )
    }
}

private struct IrohForgetCall: Equatable, Hashable {
    let macDeviceID: String
    let instanceTag: String?
    let expectedAccountID: String
}

@MainActor
private final class RecordingIrohForget: MobileIrohMacForgetting {
    private(set) var calls: [IrohForgetCall] = []

    func forgetComputer(
        macDeviceID: String,
        instanceTag: String?,
        expectedAccountID: String
    ) async throws {
        calls.append(IrohForgetCall(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            expectedAccountID: expectedAccountID
        ))
    }
}
