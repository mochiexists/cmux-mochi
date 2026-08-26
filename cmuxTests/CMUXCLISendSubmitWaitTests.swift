import Darwin
import Foundation
import Testing

private final class CMUXCLISendSubmitWaitBundleToken {}

@Suite("cmux send submit and wait", .serialized)
struct CMUXCLISendSubmitWaitTests {
    @Test(arguments: ["--enter", "--submit"])
    func submitAliasesTypeThenEnterOnResolvedSurface(submitFlag: String) throws {
        let server = try SendMockServer { request, _ in
            switch request["method"] as? String {
            case "surface.send_text", "surface.send_key":
                return ["surface_id": "resolved-surface"]
            default:
                throw SendMockServer.Failure.unexpectedMethod(request["method"] as? String)
            }
        }
        server.start()
        defer { server.stop() }

        let result = runCLI(
            ["send", submitFlag, "--force", "hello worker"],
            socketPath: server.socketPath
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let requests = server.requestObjects()
        #expect(requests.map { $0["method"] as? String } == [
            "surface.send_text",
            "surface.send_key",
        ])
        let sendParams = try #require(requests[0]["params"] as? [String: Any])
        #expect(sendParams["text"] as? String == "hello worker")
        #expect(sendParams["force"] as? Bool == true)
        let keyParams = try #require(requests[1]["params"] as? [String: Any])
        #expect(keyParams["surface_id"] as? String == "resolved-surface")
        #expect(keyParams["key"] as? String == "enter")
    }

    @Test func waitImpliesSubmitAndPrintsSettledScreen() throws {
        let screens = LockedScreens(["ready", "typed", "working", "done", "done"])
        let server = try SendMockServer { request, _ in
            switch request["method"] as? String {
            case "surface.send_text", "surface.send_key":
                return ["surface_id": "settle-surface"]
            case "surface.read_text":
                return [
                    "surface_id": "settle-surface",
                    "text": screens.next(),
                ]
            default:
                throw SendMockServer.Failure.unexpectedMethod(request["method"] as? String)
            }
        }
        server.start()
        defer { server.stop() }

        let result = runCLI(
            [
                "send", "--wait", "--wait-timeout", "2",
                "--wait-settle", "0", "--wait-poll", "1",
                "finish the task",
            ],
            socketPath: server.socketPath,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output == "done\n")
        let requests = server.requestObjects()
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods.first == "surface.read_text")
        #expect(methods.dropFirst().first == "surface.send_text")
        #expect(methods.dropFirst(2).first == "surface.read_text")
        #expect(methods.dropFirst(3).first == "surface.send_key")
        #expect(methods.dropFirst(4).allSatisfy { $0 == "surface.read_text" })
        #expect(methods.filter { $0 == "surface.read_text" }.count >= 4)
        let sendParams = try #require(requests[1]["params"] as? [String: Any])
        #expect(sendParams["text"] as? String == "finish the task")
        let keyParams = try #require(requests[3]["params"] as? [String: Any])
        #expect(keyParams["key"] as? String == "enter")
        for request in requests.dropFirst(3) {
            let params = try #require(request["params"] as? [String: Any])
            #expect(params["surface_id"] as? String == "settle-surface")
        }
    }

    @Test func waitTimesOutWhenSubmitProducesNoObservableAcknowledgement() throws {
        let server = try SendMockServer { request, _ in
            switch request["method"] as? String {
            case "surface.send_text", "surface.send_key":
                return ["surface_id": "idle-surface"]
            case "surface.read_text":
                return ["surface_id": "idle-surface", "text": "ready"]
            default:
                throw SendMockServer.Failure.unexpectedMethod(request["method"] as? String)
            }
        }
        server.start()
        defer { server.stop() }

        let result = runCLI(
            [
                "send", "--wait", "--wait-timeout", "0.12",
                "--wait-settle", "0", "--wait-poll", "10",
                "finish the task",
            ],
            socketPath: server.socketPath,
            timeout: 2
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status != 0)
        #expect(result.output.contains("no post-submit screen change"), Comment(rawValue: result.output))
    }

    @Test func literalSeparatorKeepsSubmitFlagAsMessageText() throws {
        let server = try SendMockServer { request, _ in
            guard request["method"] as? String == "surface.send_text" else {
                throw SendMockServer.Failure.unexpectedMethod(request["method"] as? String)
            }
            return ["surface_id": "literal-surface"]
        }
        server.start()
        defer { server.stop() }

        let result = runCLI(["send", "--", "--enter"], socketPath: server.socketPath)

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let requests = server.requestObjects()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request["method"] as? String == "surface.send_text")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["text"] as? String == "--enter")
    }

    @Test func invalidWaitOptionsFailBeforeSending() throws {
        let server = try SendMockServer { request, _ in
            throw SendMockServer.Failure.unexpectedMethod(request["method"] as? String)
        }
        server.start()
        defer { server.stop() }

        let result = runCLI(
            ["send", "--wait", "--wait-poll", "0", "hello"],
            socketPath: server.socketPath
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status != 0)
        #expect(result.output.contains("--wait-poll must be a positive number"))
        #expect(server.requestObjects().isEmpty)
    }

    @Test func helpDocumentsSubmitWaitAndSendOnlyContract() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: CMUXCLISendSubmitWaitBundleToken.self
        )
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["send", "help"],
            environment: cleanEnvironment(),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        for token in ["only TYPES", "--enter", "--submit", "--wait", "--force"] {
            #expect(result.output.contains(token), Comment(rawValue: result.output))
        }
        #expect(!result.output.lowercased().contains("socket not found"))
    }

    private func runCLI(
        _ arguments: [String],
        socketPath: String,
        timeout: TimeInterval = 5
    ) -> ProcessRunResult {
        let cliPath: String
        do {
            cliPath = try BundledCLITestSupport.bundledCLIPath(
                for: CMUXCLISendSubmitWaitBundleToken.self
            )
        } catch {
            return ProcessRunResult(status: -1, output: String(describing: error), timedOut: false)
        }
        return runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath] + arguments,
            environment: cleanEnvironment(),
            timeout: timeout
        )
    }

    private func cleanEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // Never inherit the developer's socket-password file or Keychain state.
        // An explicit test password makes the mock protocol deterministic.
        environment["CMUX_SOCKET_PASSWORD"] = SendMockServer.password
        return environment
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, output: String(describing: error), timedOut: false)
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            output: String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            timedOut: timedOut
        )
    }

    private struct ProcessRunResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }
}

private final class LockedScreens: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard values.count > 1 else { return values.first ?? "" }
        return values.removeFirst()
    }
}

private final class SendMockServer: @unchecked Sendable {
    static let password = "cmux-send-test-password"

    enum Failure: Error {
        case unexpectedMethod(String?)
    }

    let socketPath: String

    private let handler: @Sendable ([String: Any], Int) throws -> [String: Any]
    private let queue = DispatchQueue(label: "com.cmux.tests.send-mock-server")
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var started = false
    private var stopping = false
    private var requests: [[String: Any]] = []

    init(
        handler: @escaping @Sendable ([String: Any], Int) throws -> [String: Any]
    ) throws {
        self.socketPath = "/tmp/cmux-send-\(UUID().uuidString.prefix(8)).sock"
        self.handler = handler
        unlink(socketPath)

        listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw Self.posixError("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let buffer = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, source, maxPathLength - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(listenerFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listenerFD, 1) == 0 else {
            let error = Self.posixError("bind/listen")
            Darwin.close(listenerFD)
            listenerFD = -1
            throw error
        }
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        finished.enter()
        lock.unlock()
        queue.async { [self] in serve() }
    }

    func stop() {
        lock.lock()
        guard !stopping else {
            lock.unlock()
            return
        }
        stopping = true
        let listener = listenerFD
        let client = clientFD
        let shouldWait = started
        lock.unlock()

        if client >= 0 { _ = Darwin.shutdown(client, SHUT_RDWR) }
        if listener >= 0 { _ = Darwin.shutdown(listener, SHUT_RDWR) }
        if shouldWait { _ = finished.wait(timeout: .now() + 2) }
        unlink(socketPath)
    }

    func requestObjects() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func serve() {
        defer { finished.leave() }
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let client = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.accept(listenerFD, socketPointer, &length)
            }
        }
        guard client >= 0 else { return }
        lock.lock()
        clientFD = client
        lock.unlock()
        defer {
            Darwin.close(client)
            Darwin.close(listenerFD)
        }

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)

            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                if String(data: lineData, encoding: .utf8) == "auth \(Self.password)" {
                    let authResponse = Data("OK\n".utf8)
                    authResponse.withUnsafeBytes { bytes in
                        if let baseAddress = bytes.baseAddress {
                            _ = Darwin.write(client, baseAddress, bytes.count)
                        }
                    }
                    continue
                }
                guard let request = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let id = request["id"] as? String else {
                    continue
                }
                lock.lock()
                requests.append(request)
                let requestIndex = requests.count - 1
                lock.unlock()

                let response: [String: Any]
                do {
                    response = [
                        "id": id,
                        "ok": true,
                        "result": try handler(request, requestIndex),
                    ]
                } catch {
                    response = [
                        "id": id,
                        "ok": false,
                        "error": [
                            "code": "unexpected_method",
                            "message": String(describing: error),
                        ],
                    ]
                }
                guard let data = try? JSONSerialization.data(withJSONObject: response) else { continue }
                var responseData = data
                responseData.append(0x0A)
                responseData.withUnsafeBytes { bytes in
                    if let baseAddress = bytes.baseAddress {
                        _ = Darwin.write(client, baseAddress, bytes.count)
                    }
                }
            }
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
        )
    }
}
