import CmuxWorkspaces
import Testing

@Suite struct DefaultWorkspaceWorkingDirectoryPolicyTests {
    private let homeDirectory = "/Users/tester"
    private let repositoryRoot = "/Users/tester/src/cmux"
    private let scratchDirectory = "/Users/tester/Library/Application Support/cmux/dev-scratch/e2e-mobile"

    @Test func debugHomeUsesExistingRepositoryRoot() {
        #expect(
            resolve(
                candidate: homeDirectory,
                repositoryRoot: repositoryRoot,
                existingDirectories: [repositoryRoot]
            ) == repositoryRoot
        )
    }

    @Test func debugRootUsesScratchWhenRepositoryRootIsMissing() {
        #expect(
            resolve(
                candidate: "/",
                repositoryRoot: repositoryRoot,
                existingDirectories: []
            ) == scratchDirectory
        )
    }

    @Test func debugHomeUsesScratchWithoutRepositoryRoot() {
        #expect(
            resolve(
                candidate: homeDirectory,
                repositoryRoot: nil,
                existingDirectories: []
            ) == scratchDirectory
        )
    }

    @Test func explicitSafeDirectoryWins() {
        let explicitDirectory = "/tmp/explicit-project"
        #expect(
            resolve(
                candidate: explicitDirectory,
                repositoryRoot: repositoryRoot,
                existingDirectories: [repositoryRoot, explicitDirectory]
            ) == explicitDirectory
        )
    }

    @Test(arguments: ["/Users/tester", "/"])
    func releaseBehaviorIsUnchanged(_ candidate: String) {
        #expect(
            resolve(
                candidate: candidate,
                repositoryRoot: repositoryRoot,
                existingDirectories: [repositoryRoot],
                isDebugBuild: false
            ) == candidate
        )
    }

    private func resolve(
        candidate: String,
        repositoryRoot: String?,
        existingDirectories: Set<String>,
        isDebugBuild: Bool = true
    ) -> String {
        DefaultWorkspaceWorkingDirectoryPolicy(
            isDebugBuild: isDebugBuild,
            homeDirectory: homeDirectory,
            repositoryRoot: repositoryRoot,
            scratchDirectory: scratchDirectory
        ).resolve(candidate: candidate) { path in
            existingDirectories.contains(path)
        }
    }
}
