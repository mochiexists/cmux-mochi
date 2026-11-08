import Testing
@testable import CmuxTerminal

@Suite
struct TerminalWorkingDirectoryLaunchPlanTests {
    private static let home = "/Users/someone"
    private static let project = "/Users/someone/Documents/it's a project"

    @Test
    func reachableDirectoryIsPassedThrough() {
        let plan = TerminalWorkingDirectoryLaunchPlan.resolve(
            requestedWorkingDirectory: Self.project,
            initialInput: "claude --resume\n",
            inputReachesShell: true,
            gate: gate(answering: true)
        )

        #expect(plan == TerminalWorkingDirectoryLaunchPlan(
            workingDirectory: Self.project,
            initialInput: "claude --resume\n",
            deferredWorkingDirectory: nil
        ))
    }

    @Test
    func stalledDirectoryStartsShellInHomeAndTypesCdFirst() {
        let probe = BlockingDirectoryProbe()
        defer { probe.answer() }

        let plan = TerminalWorkingDirectoryLaunchPlan.resolve(
            requestedWorkingDirectory: Self.project,
            initialInput: "claude --resume\n",
            inputReachesShell: true,
            gate: TerminalWorkingDirectoryAccessGate(
                deadline: .milliseconds(20),
                homeDirectory: Self.home,
                probe: probe.open
            )
        )

        #expect(plan.workingDirectory == Self.home)
        #expect(plan.initialInput == "cd '/Users/someone/Documents/it'\\''s a project' && claude --resume\n")
        #expect(plan.deferredWorkingDirectory == Self.project)
    }

    @Test
    func stalledDirectoryWithoutPlannedInputTypesOnlyTheCd() {
        let probe = BlockingDirectoryProbe()
        defer { probe.answer() }

        let plan = TerminalWorkingDirectoryLaunchPlan.resolve(
            requestedWorkingDirectory: "/Users/someone/Documents/app",
            initialInput: nil,
            inputReachesShell: true,
            gate: TerminalWorkingDirectoryAccessGate(
                deadline: .milliseconds(20),
                homeDirectory: Self.home,
                probe: probe.open
            )
        )

        #expect(plan.initialInput == "cd '/Users/someone/Documents/app'\n")
    }

    @Test
    func stalledDirectoryWithExplicitCommandStartsInHomeWithoutTypedCd() {
        let probe = BlockingDirectoryProbe()
        defer { probe.answer() }

        let plan = TerminalWorkingDirectoryLaunchPlan.resolve(
            requestedWorkingDirectory: Self.project,
            initialInput: nil,
            inputReachesShell: false,
            gate: TerminalWorkingDirectoryAccessGate(
                deadline: .milliseconds(20),
                homeDirectory: Self.home,
                probe: probe.open
            )
        )

        #expect(plan.workingDirectory == Self.home)
        #expect(plan.initialInput == nil)
        #expect(plan.deferredWorkingDirectory == Self.project)
    }

    @Test(arguments: [nil, "", home])
    func homeOrNoDirectoryNeverProbes(requested: String?) {
        let probe = BlockingDirectoryProbe()
        defer { probe.answer() }
        let gate = TerminalWorkingDirectoryAccessGate(
            deadline: .milliseconds(20),
            homeDirectory: Self.home,
            probe: probe.open
        )

        let plan = TerminalWorkingDirectoryLaunchPlan.resolve(
            requestedWorkingDirectory: requested,
            initialInput: nil,
            inputReachesShell: true,
            gate: gate
        )

        #expect(plan.workingDirectory == requested)
        #expect(plan.deferredWorkingDirectory == nil)
        #expect(probe.startCount == 0)
    }

    @Test(arguments: [
        (nil, nil, false, true),
        ("", "", false, true),
        ("claude --resume x", nil, false, false),
        (nil, "/bin/htop", false, false),
        (nil, nil, true, false),
    ] as [(String?, String?, Bool, Bool)])
    func startupInputReachesShellOnlyWithoutAnExplicitCommand(
        initialCommand: String?,
        surfaceCommand: String?,
        hasUserGhosttyCommand: Bool,
        expected: Bool
    ) {
        #expect(TerminalSurface.startupInputReachesShell(
            initialCommand: initialCommand,
            surfaceCommand: surfaceCommand,
            hasUserGhosttyCommand: hasUserGhosttyCommand
        ) == expected)
    }

    private func gate(answering opened: Bool) -> TerminalWorkingDirectoryAccessGate {
        TerminalWorkingDirectoryAccessGate(
            deadline: .milliseconds(50),
            homeDirectory: Self.home,
            probe: { _ in opened }
        )
    }
}
