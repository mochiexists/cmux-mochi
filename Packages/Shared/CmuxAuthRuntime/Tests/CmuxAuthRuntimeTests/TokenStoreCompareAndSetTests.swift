import Foundation
import Testing
@testable import CmuxAuthRuntime

@Suite struct TokenStoreCompareAndSetTests {
    @Test func fileStoreDoubleNilCompareAndSetClearsMatchingTokens() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileStackTokenStore(directory: directory)
        await store.setTokens(accessToken: "access-1", refreshToken: "refresh-1")

        await store.compareAndSet(
            compareRefreshToken: "refresh-1",
            newRefreshToken: nil,
            newAccessToken: nil
        )

        #expect(await store.getStoredAccessToken() == nil)
        #expect(await store.getStoredRefreshToken() == nil)

        let freshStore = FileStackTokenStore(directory: directory)
        #expect(await freshStore.getStoredAccessToken() == nil)
        #expect(await freshStore.getStoredRefreshToken() == nil)
    }

    @Test func fileStoreDoubleNilCompareAndSetPreservesTokensWhenCompareIsStale() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileStackTokenStore(directory: directory)
        await store.setTokens(accessToken: "access-1", refreshToken: "refresh-1")

        await store.compareAndSet(
            compareRefreshToken: "stale-refresh",
            newRefreshToken: nil,
            newAccessToken: nil
        )

        #expect(await store.getStoredAccessToken() == "access-1")
        #expect(await store.getStoredRefreshToken() == "refresh-1")
    }

    @Test func fileStoreCompareAndSetUpdatesTokensWhenCompareMatches() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileStackTokenStore(directory: directory)
        await store.setTokens(accessToken: "access-1", refreshToken: "refresh-1")

        await store.compareAndSet(
            compareRefreshToken: "refresh-1",
            newRefreshToken: "refresh-2",
            newAccessToken: "access-2"
        )

        #expect(await store.getStoredAccessToken() == "access-2")
        #expect(await store.getStoredRefreshToken() == "refresh-2")
    }

    @Test func fallbackStoreDoubleNilCompareAndSetClearsFileSeededTokens() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainTokenStore()
        let file = FileStackTokenStore(directory: directory)
        await file.setTokens(accessToken: "access-1", refreshToken: "refresh-1")
        let store = FallbackTokenStore(primary: keychain, fallback: file)

        await store.compareAndSet(
            compareRefreshToken: "refresh-1",
            newRefreshToken: nil,
            newAccessToken: nil
        )

        #expect(await store.getStoredAccessToken() == nil)
        #expect(await store.getStoredRefreshToken() == nil)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxAuthRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}

private actor InMemoryKeychainTokenStore: KeychainStackTokenStoring {
    private var accessToken: String?
    private var refreshToken: String?

    func getStoredAccessToken() async -> String? { accessToken }
    func getStoredRefreshToken() async -> String? { refreshToken }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func trySetTokens(accessToken: String?, refreshToken: String?) async -> Bool {
        await setTokens(accessToken: accessToken, refreshToken: refreshToken)
        return true
    }

    func clearTokens() async {
        accessToken = nil
        refreshToken = nil
    }

    func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        guard self.accessToken == accessToken, self.refreshToken == refreshToken else { return false }
        await clearTokens()
        return true
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        guard refreshToken == compareRefreshToken else { return }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }
}
