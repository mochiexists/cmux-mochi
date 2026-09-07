import Darwin
import Foundation
import Testing
import XCTest

enum BundledCLITestSupport {
    static func bundledCLIPath(
        for bundleClass: AnyClass,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try bundledCLIURL(for: bundleClass, file: file, line: line).path
    }

    static func bundledCLIURL(
        for bundleClass: AnyClass,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: bundleClass)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedCLIURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)

        if fileManager.isExecutableFile(atPath: expectedCLIURL.path) {
            return expectedCLIURL
        }

        let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux"),
                  fileManager.isExecutableFile(atPath: item.path) else { continue }
            return item
        }

        let message = "Bundled cmux CLI not found at \(expectedCLIURL.path)"
        XCTFail(message, file: file, line: line)
        throw NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}

@Suite
final class BundledCLILinkageTests {
    @Test
    func bundledCLIStartsAfterRelocationAndRequiresItsBundledFrameworks() throws {
        let fileManager = FileManager.default
        let cliURL = try BundledCLITestSupport.bundledCLIURL(for: Self.self)
        let contentsURL = cliURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-relocation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let relocatedContentsURL = temporaryURL.appendingPathComponent("Relocated.app/Contents", isDirectory: true)
        let relocatedResourcesURL = relocatedContentsURL.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: relocatedResourcesURL, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: contentsURL.appendingPathComponent("Resources/bin", isDirectory: true),
            to: relocatedResourcesURL.appendingPathComponent("bin", isDirectory: true)
        )
        let relocatedFrameworksURL = relocatedContentsURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.copyItem(
            at: contentsURL.appendingPathComponent("Frameworks", isDirectory: true),
            to: relocatedFrameworksURL
        )
        let relocatedCLIURL = relocatedResourcesURL.appendingPathComponent("bin/cmux")
        try #require(
            relocatedCLIURL.resolvingSymlinksInPath().path.hasPrefix(
                temporaryURL.resolvingSymlinksInPath().path + "/"
            ),
            "The relocated CLI must not be a symlink back into the original build."
        )
        let installedBinURL = temporaryURL.appendingPathComponent("installed/bin", isDirectory: true)
        try fileManager.createDirectory(at: installedBinURL, withIntermediateDirectories: true)
        let installedCLIURL = installedBinURL.appendingPathComponent("cmux")
        try fileManager.createSymbolicLink(at: installedCLIURL, withDestinationURL: relocatedCLIURL)

        // The installed CLI is a symlink into the app, whose relative rpath
        // resolves Contents/Frameworks. A copied helper alone is not the payload.
        // Another Mac has none of this builder's absolute search directories.
        // Remove only those rpaths from private COPIES to model that absence:
        // the shipping executable, system paths, and relative bundle paths stay
        // untouched. Frameworks need the same treatment because their own Debug
        // rpaths can otherwise rescue a deliberately missing dependency.
        let copiedBinaries = [relocatedCLIURL] + (try machOBinaries(in: relocatedFrameworksURL))
        for binaryURL in copiedBinaries {
            try removeBuildRunpaths(from: binaryURL, inside: temporaryURL)
        }
        let completePayload = try runProcess(installedCLIURL.path, arguments: ["--version"])
        try #require(completePayload.exitCode == 0, "Relocated CLI failed: \(completePayload.output)")
        #expect(completePayload.output.lowercased().contains("cmux"))

        let dependency = try #require(try linkedLibraries(for: cliURL).first {
            $0.hasPrefix("@rpath/") && $0.contains(".framework/")
        }, "Expected the current bundled CLI's package framework dependency.")
        let frameworkName = String(dependency.dropFirst("@rpath/".count).prefix { $0 != "/" })
        let requiredFrameworkURL = relocatedFrameworksURL.appendingPathComponent(frameworkName)
        try #require(fileManager.fileExists(atPath: requiredFrameworkURL.path))
        try fileManager.moveItem(
            at: requiredFrameworkURL,
            to: temporaryURL.appendingPathComponent("withheld-\(frameworkName)")
        )

        let incompletePayload = try runProcess(installedCLIURL.path, arguments: ["--version"])
        #expect(incompletePayload.exitCode != 0, "CLI unexpectedly found its removed bundled framework.")
        #expect(incompletePayload.output.contains(frameworkName), "Expected missing-framework diagnostic: \(incompletePayload.output)")
        #expect(incompletePayload.output.lowercased().contains("dyld"), "Expected dyld load failure: \(incompletePayload.output)")
    }

    private func linkedLibraries(for executableURL: URL) throws -> [String] {
        let result = try runProcess("/usr/bin/otool", arguments: ["-L", executableURL.path])
        try #require(result.exitCode == 0, "otool failed: \(result.output)")
        return result.output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> String? in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ")
                    .first
                    .map(String.init)
            }
    }

    private func absoluteBuildRunpaths(for executableURL: URL) throws -> [String] {
        let result = try runProcess("/usr/bin/otool", arguments: ["-l", executableURL.path])
        try #require(result.exitCode == 0, "otool failed: \(result.output)")
        var readingRunpath = false
        var paths: [String] = []
        for rawLine in result.output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cmd ") {
                readingRunpath = line == "cmd LC_RPATH"
            } else if readingRunpath, line.hasPrefix("path ") {
                let path = String(line.dropFirst(5)).components(separatedBy: " (offset ")[0]
                if path.hasPrefix("/"), !path.hasPrefix("/usr/lib/"), !path.hasPrefix("/System/Library/") {
                    paths.append(path)
                }
                readingRunpath = false
            }
        }
        return paths
    }

    private func removeBuildRunpaths(from binaryURL: URL, inside temporaryURL: URL) throws {
        try #require(
            binaryURL.resolvingSymlinksInPath().path.hasPrefix(temporaryURL.resolvingSymlinksInPath().path + "/"),
            "Only the private copied payload may be modified."
        )
        let paths = Set(try absoluteBuildRunpaths(for: binaryURL)).sorted()
        guard !paths.isEmpty else { return }
        let edit = try runProcess("/usr/bin/install_name_tool", arguments:
            paths.flatMap { ["-delete_rpath", $0] } + [binaryURL.path]
        )
        try #require(edit.exitCode == 0, "Cannot isolate copied rpaths: \(edit.output)")
        let sign = try runProcess("/usr/bin/codesign", arguments: ["--force", "--sign", "-", "--timestamp=none", binaryURL.path])
        try #require(sign.exitCode == 0, "Cannot sign private copied binary: \(sign.output)")
        #expect(try absoluteBuildRunpaths(for: binaryURL).isEmpty)
    }

    private func machOBinaries(in directoryURL: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = try #require(FileManager.default.enumerator(
            at: directoryURL, includingPropertiesForKeys: Array(keys)
        ))
        let magicValues: Set<Data> = [
            Data([0xfe, 0xed, 0xfa, 0xce]), Data([0xce, 0xfa, 0xed, 0xfe]),
            Data([0xfe, 0xed, 0xfa, 0xcf]), Data([0xcf, 0xfa, 0xed, 0xfe]),
            Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
            Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca]),
        ]
        var binaries: [URL] = []
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            let header = try handle.read(upToCount: 4)
            try handle.close()
            if let header, magicValues.contains(header) {
                binaries.append(url)
            }
        }
        return binaries
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> (exitCode: Int32, output: String) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-linkage-output-\(UUID().uuidString)")
        try Data().write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("__XPC_DYLD_")
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let finished = exited.wait(timeout: .now() + 15) == .success
        if !finished {
            process.terminate()
            if exited.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try #require(finished, "Timed out running \(executable).")
        return (process.terminationStatus, String(decoding: try Data(contentsOf: outputURL), as: UTF8.self))
    }
}
