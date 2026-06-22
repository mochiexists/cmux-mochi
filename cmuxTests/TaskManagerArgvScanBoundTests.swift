import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the Task Manager app-hang (Sentry CMUX-ATLAS-1R).
///
/// `CmuxTaskManagerCodingAgentDefinition.matchingDefinition` ran an unbounded
/// per-argument scan (`first { contains { contains { … } } }` plus per-argument
/// `lowercased()` bridging). Driven every 3s by the always-on sidebar resource
/// poller, a single process carrying a very large argv could push the pass past
/// the 8s app-hang threshold and freeze the UI (new tabs failing to render,
/// Cmd-Q not landing). The scan is now bounded to the first N arguments —
/// coding agents are always identified by their binary or an early subcommand
/// argument, never by a token thousands of args deep.
final class TaskManagerArgvScanBoundTests: XCTestCase {
    /// An agent needle that appears only far past the scan bound must NOT match:
    /// scanning that deep is exactly the O(args) cost that caused the hang.
    func testNeedleBeyondArgvScanBoundIsNotMatched() {
        var arguments = ["/usr/local/bin/node"]
        // Well past any reasonable scan bound — a real agent's identifying token
        // never lives this deep in argv.
        arguments.append(contentsOf: (0..<5000).map { "filler-arg-\($0)" })
        arguments.append("cursor-agent") // cursor's argumentNeedle, only at the tail

        let match = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "node",
            processPath: "/usr/local/bin/node",
            arguments: arguments,
            environment: [:]
        )

        XCTAssertNil(
            match,
            "An agent needle far beyond the argv scan bound must not match; "
                + "scanning that far is the cost that froze the main thread."
        )
    }

    /// Control: a needle within the scan bound still matches, proving the bound
    /// does not regress normal coding-agent detection.
    func testNeedleWithinArgvScanBoundStillMatches() throws {
        let arguments = ["/usr/local/bin/node", "cursor-agent"]

        let match = try XCTUnwrap(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "node",
            processPath: "/usr/local/bin/node",
            arguments: arguments,
            environment: [:]
        ))

        XCTAssertEqual(match.id, "cursor")
    }
}
