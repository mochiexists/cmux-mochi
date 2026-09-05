import Foundation
import Testing
import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> @Sendable (String) -> Bool {
    { path in existingPaths.contains((path as NSString).standardizingPath) }
}

@Suite struct TerminalPathTrailingPunctuationTests {
    @Test func trimsTrailingPeriodAfterMarkdownFile() {
        #expect(
            "~/ClaudeCode/feature-spec-template.md.".trimmingTrailingTerminalPunctuation()
                == "~/ClaudeCode/feature-spec-template.md"
        )
    }

    @Test func trimsTrailingCommaInList() {
        #expect(
            "/tmp/fixtures/first.txt,".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/first.txt"
        )
    }

    @Test func trimsTrailingCloseParenWhenNoBalancedOpenParen() {
        #expect(
            "/tmp/fixtures/notes.txt)".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }

    @Test func preservesBalancedParensInMiddleOfPath() {
        #expect(
            "/tmp/fixtures/report (draft)/notes.txt".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/report (draft)/notes.txt"
        )
    }

    @Test func stripsMultipleTrailingPunctuationCharacters() {
        #expect(
            "/tmp/fixtures/report (draft).md).,!?\"".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/report (draft).md"
        )
    }

    @Test func trimsTrailingClosingQuote() {
        #expect(
            "/tmp/fixtures/notes.txt\"".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }
}

@Suite struct TerminalQuicklookPathResolutionTests {
    @Test func fallsBackToStrippedPathWhenLiteralPathIsMissing() {
        let strippedPath = "/tmp/cmux-cmdclick-path.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([strippedPath])).resolveQuicklookPath(
                "\(strippedPath).",
                cwd: "/tmp"
            ) == strippedPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithDot() {
        let literalPath = "/tmp/cmux-cmdclick-literal-dot.md."
        let strippedPath = "/tmp/cmux-cmdclick-literal-dot.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithParen() {
        let literalPath = "/tmp/cmux-cmdclick-literal-paren)"
        let strippedPath = "/tmp/cmux-cmdclick-literal-paren"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func resolvesRelativeMarkdownPathWithTrailingDot() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "docs/specs/2026-05-22-test.md.",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func resolvesRelativePathWithTrailingComma() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/src/main.swift"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "src/main.swift,",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func resolvesRepositoryRelativePathWhenCwdAlreadyIncludesLeadingDirectory() {
        let cwd = "/Users/dev/project/external/nirvana"
        let existingFile = "/Users/dev/project/external/nirvana/PHILOSOPHY.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "nirvana/PHILOSOPHY.md",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func returnsNilForRelativePathThatDoesNotExist() {
        #expect(
            TerminalPathResolver(fileExists: existsIn([])).resolveQuicklookPath(
                "docs/nonexistent.md.",
                cwd: "/Users/dev/project"
            ) == nil
        )
    }

    @Test func relativeCandidateWithoutCwdIsSkipped() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveQuicklookPath(
                "src/main.swift",
                cwd: nil
            ) == nil
        )
    }

    @Test func unquotesShellQuotedToken() {
        let existingFile = "/tmp/cmux quicklook spaced.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "\"\(existingFile)\"",
                cwd: "/tmp"
            ) == existingFile
        )
    }

    @Test func unescapesBackslashEscapedSpaces() {
        let existingFile = "/tmp/cmux quicklook escaped.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "/tmp/cmux\\ quicklook\\ escaped.md",
                cwd: "/tmp"
            ) == existingFile
        )
    }
}

@Suite struct TerminalOpenURLFilePathTests {
    @Test func resolvesAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                "\(existingFile).",
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func resolvesQuotedAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                "\"\(existingFile).\"",
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func textWithURLSchemeIsNeverTreatedAsFilePath() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "file:///tmp/test.md",
                cwd: "/tmp"
            ) == nil
        )
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "mailto:test@example.com",
                cwd: "/tmp"
            ) == nil
        )
    }

    @Test func schemelessRelativeAndAbsoluteTextStaysEligible() {
        let relative = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([relative])).resolveOpenURLFilePath(
                "docs/specs/2026-05-22-test.md.",
                cwd: "/Users/dev/project"
            ) == relative
        )
    }
}

@Suite struct TerminalVisibleLineResolutionTests {
    private let reportPath = "/Users/dev/Documents/Github/test-project/docs/audits/report.html"

    @Test func resolvesIndentedAbsoluteReportContinuationWithUnrelatedCWD() throws {
        let lines = ["Open report (/Users/dev/", "  Documents/Github/test-project/docs/audits/report.html), which tracks requirements."]
        let resolver = TerminalPathResolver(fileExists: existsIn([reportPath]))
        for (row, column) in [(0, 18), (1, 10)] {
            let result = try #require(resolver.resolveVisiblePath(lines, row: row, column: column, cwd: "/tmp"))
            #expect(result.path == reportPath)
        }
    }

    @Test func existingSingleLineTargetWinsOverPossibleContinuation() throws {
        let localPath = "/tmp/Documents/Github/test-project/docs/audits/report.html"
        let lines = ["/Users/dev/", "  Documents/Github/test-project/docs/audits/report.html"]
        let resolver = TerminalPathResolver(fileExists: existsIn([reportPath, localPath]))
        let result = try #require(resolver.resolveVisiblePath(lines, row: 1, column: 10, cwd: "/tmp"))
        #expect(result.path == localPath)
    }

    @Test func rejectsMissingFileAndUnrelatedPointerPosition() {
        let lines = ["Open report (/Users/dev/", "  Documents/Github/test-project/docs/audits/report.html) other"]
        #expect(TerminalPathResolver(fileExists: { _ in false }).resolveVisiblePath(lines, row: 1, column: 10, cwd: "/tmp") == nil)
        let resolver = TerminalPathResolver(fileExists: existsIn([reportPath]))
        #expect(resolver.resolveVisiblePath(lines, row: 1, column: 60, cwd: "/tmp") == nil)
        #expect(resolver.resolveVisiblePath(lines, row: 0, column: 1, cwd: "/tmp") == nil)
    }

    @Test(arguments: ["  /Documents/report.html", "  ./Documents/report.html", "  https://Documents/report.html", "Documents/report.html", "                 Documents/report.html"])
    func doesNotJoinIndependentOrUnindentedRows(_ continuation: String) {
        let resolver = TerminalPathResolver(fileExists: existsIn(["/Users/dev/Documents/report.html"]))
        #expect(resolver.resolveVisiblePath(["/Users/dev/", continuation], row: 1, column: 4, cwd: "/tmp") == nil)
    }

    @Test func callbackRequiresMatchingSchemelessVisibleFragment() {
        let token = "Documents/Github/report.html),"
        #expect(TerminalPathResolver.openURLMatchesVisibleToken("Documents/Github/report.html", token: token))
        for rawValue in ["https://Documents/Github/report.html", "file:///tmp/report.html", "other/report.html"] {
            #expect(!TerminalPathResolver.openURLMatchesVisibleToken(rawValue, token: token))
        }
    }

    @Test func boundsContinuationToThreeRowsAndRequiresFile() throws {
        let resolver = TerminalPathResolver(fileExists: existsIn([reportPath]))
        let threeRows = ["/Users/dev/", "  Documents/Github/", "  test-project/docs/audits/report.html"]
        #expect(try #require(resolver.resolveVisiblePath(threeRows, row: 2, column: 8, cwd: "/tmp")).path == reportPath)
        let fourRows = ["/Users/dev/", "  Documents/", "  Github/", "  test-project/docs/audits/report.html"]
        #expect(resolver.resolveVisiblePath(fourRows, row: 3, column: 8, cwd: "/tmp") == nil)
        let directoryResolver = TerminalPathResolver(fileExists: existsIn([reportPath]), isDirectory: { _ in true })
        #expect(directoryResolver.resolveVisiblePath(threeRows, row: 2, column: 8, cwd: "/tmp") == nil)
    }

    @Test func visibleLinesKeepsTrailingRowsOnly() {
        let text = "one\ntwo\nthree\nfour"
        #expect(text.visibleLines(rows: 2) == ["three", "four"])
        #expect(text.visibleLines(rows: 10) == ["one", "two", "three", "four"])
    }

    @Test func visibleLinesPreservesEmptyLines() {
        #expect("a\n\nb".visibleLines(rows: 3) == ["a", "", "b"])
    }

    @Test func resolvesRawSegmentUnderColumn() throws {
        let existingFile = "/tmp/cmux-visible-line.md"
        let line = "open /tmp/cmux-visible-line.md now"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: 8,
                cwd: "/tmp"
            )
        )
        #expect(resolution.path == existingFile)
        #expect(resolution.rawToken == "/tmp/cmux-visible-line.md")
    }

    @Test func resolvesShellEscapedTokenSpanningSpaces() throws {
        let existingFile = "/tmp/cmux visible escaped.md"
        let line = "cat /tmp/cmux\\ visible\\ escaped.md"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: 6,
                cwd: "/tmp"
            )
        )
        #expect(resolution.path == existingFile)
    }

    @Test func returnsNilWhenColumnSitsOnHardDelimiter() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveVisibleLinePath(
                "a\tb",
                column: 1,
                cwd: "/tmp"
            ) == nil
        )
    }
}
