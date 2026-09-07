import Testing

@testable import CmuxSettingsUI

@Suite struct MobilePairingPortFieldValueTests {
    @Test func channelConfiguredPortOverridesCatalogSeedWhenUserIsNotEditing() {
        #expect(MobilePairingPortFieldValue.resolve(
            editedPort: nil,
            persistedPort: 58_465,
            statusConfiguredPort: 58_466
        ) == 58_466)
    }

    @Test func activeEditOverridesLiveConfiguredPort() {
        #expect(MobilePairingPortFieldValue.resolve(
            editedPort: 59_000,
            persistedPort: 58_465,
            statusConfiguredPort: 58_466
        ) == 59_000)
    }

    @Test func persistedPortIsFallbackBeforeHostStatusArrives() {
        #expect(MobilePairingPortFieldValue.resolve(
            editedPort: nil,
            persistedPort: 58_465,
            statusConfiguredPort: nil
        ) == 58_465)
    }
}
