import XCTest
import Darwin

enum CLIMockSocketAuthentication {
    static let password = "cmux-cli-mock-socket-password"

    static func environment(
        _ environment: [String: String],
        password: String = CLIMockSocketAuthentication.password
    ) -> [String: String] {
        var isolated = environment
        // A nonempty explicit password wins over the developer's environment,
        // password file, and Keychain, including in child hook processes.
        isolated["CMUX_SOCKET_PASSWORD"] = password
        return isolated
    }

    static func response(
        to line: String,
        password: String = CLIMockSocketAuthentication.password
    ) -> String? {
        guard line == "auth \(password)" else { return nil }
        return "OK\n"
    }
}

extension CLINotifyProcessIntegrationRegressionTests {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
        private struct ServerConfiguration: @unchecked Sendable {
            let expectation: XCTestExpectation?
            let fulfillWhen: (@Sendable (String) -> Bool)?
            let socketPassword: String
            let handler: @Sendable (String) -> String?
            var didFulfill = false
        }

        private let lock = NSLock()
        private let commandSemaphore = DispatchSemaphore(value: 0)
        private var recordedCommands: [String] = []
        private var commandTimestamps: [TimeInterval] = []
        private var serverListenerFD: Int32?
        private var serverConfiguration: ServerConfiguration?

        var commands: [String] {
            settledSnapshot()
        }

        func append(_ command: String) {
            lock.lock()
            recordedCommands.append(command)
            commandTimestamps.append(ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            commandSemaphore.signal()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = recordedCommands
            lock.unlock()
            return value
        }

        func timestampedSnapshot() -> [(command: String, timestamp: TimeInterval)] {
            lock.lock()
            let value = zip(recordedCommands, commandTimestamps).map {
                (command: $0.0, timestamp: $0.1)
            }
            lock.unlock()
            return value
        }

        private func settledSnapshot() -> [String] {
            while commandSemaphore.wait(timeout: .now()) == .success {}
            while commandSemaphore.wait(timeout: .now() + 0.1) == .success {
                while commandSemaphore.wait(timeout: .now()) == .success {}
            }
            return snapshot()
        }

        func configureServer(
            listenerFD: Int32,
            expectation: XCTestExpectation?,
            fulfillWhen: (@Sendable (String) -> Bool)?,
            socketPassword: String,
            handler: @escaping @Sendable (String) -> String?
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            serverConfiguration = ServerConfiguration(
                expectation: expectation,
                fulfillWhen: fulfillWhen,
                socketPassword: socketPassword,
                handler: handler
            )
            guard serverListenerFD != listenerFD else { return false }
            serverListenerFD = listenerFD
            return true
        }

        func response(to line: String) -> String? {
            lock.lock()
            guard let configuration = serverConfiguration else {
                lock.unlock()
                return nil
            }
            lock.unlock()

            if let authentication = CLIMockSocketAuthentication.response(
                to: line,
                password: configuration.socketPassword
            ) {
                return authentication.trimmingCharacters(in: .newlines)
            }

            append(line)
            if configuration.fulfillWhen?(line) == true || configuration.fulfillWhen == nil {
                fulfillCurrentServerExpectation()
            }
            if let request = Self.jsonObject(line),
               let method = request["method"] as? String {
                if method == "system.top", let id = request["id"] as? String {
                    return Self.v2Response(id: id, result: ["windows": []])
                }
                if method == "vm.attach_info",
                   let translated = Self.jsonLine(request, replacingMethod: "vm.ssh_info"),
                   let response = configuration.handler(translated),
                   Self.isSuccessfulV2Response(response) {
                    return response
                }
                if method == "vm.ssh_info",
                   let translated = Self.jsonLine(request, replacingMethod: "vm.attach_info"),
                   let response = configuration.handler(translated),
                   Self.isSuccessfulV2Response(response) {
                    return response
                }
            }
            return configuration.handler(line)
        }

        private static func jsonObject(_ line: String) -> [String: Any]? {
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        private static func jsonLine(
            _ request: [String: Any],
            replacingMethod method: String
        ) -> String? {
            var translated = request
            translated["method"] = method
            guard let data = try? JSONSerialization.data(withJSONObject: translated) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func isSuccessfulV2Response(_ response: String?) -> Bool {
            guard let response,
                  let payload = jsonObject(response) else { return false }
            return payload["ok"] as? Bool == true
        }

        private static func v2Response(id: String, result: [String: Any]) -> String {
            let payload: [String: Any] = ["id": id, "ok": true, "result": result]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        func fulfillCurrentServerExpectation() {
            let expectation: XCTestExpectation?
            lock.lock()
            if var configuration = serverConfiguration,
               !configuration.didFulfill {
                configuration.didFulfill = true
                serverConfiguration = configuration
                expectation = configuration.expectation
            } else {
                expectation = nil
            }
            lock.unlock()
            expectation?.fulfill()
        }
    }

    struct LoopbackTCPListener {
        let fd: Int32
        let port: Int
    }

    func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cli-\(name.prefix(3))-\(shortID).sock"
    }

    func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        XCTAssertLessThan(utf8.count, maxPathLength)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        return fd
    }

    func bindLoopbackTCP() throws -> LoopbackTCPListener {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to create TCP socket",
            ])
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to bind TCP socket",
            ])
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to listen on TCP socket",
            ])
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.getsockname(fd, sockaddrPtr, &boundLen)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to read TCP socket port",
            ])
        }

        return LoopbackTCPListener(fd: fd, port: Int(UInt16(bigEndian: boundAddr.sin_port)))
    }

    func waitForSocketFile(at path: String, timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return FileManager.default.fileExists(atPath: path)
    }

    func startBridgeErrorServer(listenerFD: Int32, message: String) -> XCTestExpectation {
        let handled = expectation(description: "pty bridge error server handled")
        Thread.detachNewThread {
            defer { handled.fulfill() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let payload: [String: Any] = ["type": "error", "message": message]
            guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(clientFD, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
        return handled
    }

    func startBridgeReadyThenCloseServer(listenerFD: Int32) -> XCTestExpectation {
        let handled = expectation(description: "pty bridge ready close server handled")
        Thread.detachNewThread {
            defer { handled.fulfill() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let payload: [String: Any] = ["type": "ready", "attachment_token": "attach-token"]
            guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(clientFD, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
        return handled
    }

    func startBridgeReadyThenResetAfterClientEOFServer(listenerFD: Int32) -> XCTestExpectation {
        let handled = expectation(description: "pty bridge ready reset server handled")
        Thread.detachNewThread {
            defer { handled.fulfill() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let payload: [String: Any] = ["type": "ready", "attachment_token": "attach-token"]
            guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(clientFD, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }

            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                return
            }

            var lingerOption = linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_LINGER,
                &lingerOption,
                socklen_t(MemoryLayout.size(ofValue: lingerOption))
            )
        }
        return handled
    }

    func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    func malformedRequestResponse(id: String? = nil, raw: String) -> String {
        v2Response(
            id: id ?? "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    func surfaceListResponse(id: String, surfaceId: String) -> String {
        v2Response(
            id: id,
            ok: true,
            result: ["surfaces": [["id": surfaceId, "ref": "surface:1", "index": 1, "focused": true]]]
        )
    }

    func processTimeout(_ requested: TimeInterval) -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" else {
            return requested
        }
        return max(requested, 20)
    }

    func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval,
        socketPassword: String = CLIMockSocketAuthentication.password
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var processEnvironment = CLIMockSocketAuthentication.environment(
            environment,
            password: socketPassword
        )
        if processEnvironment["CMUX_CLI_TEST_SSH_EXECUTABLE"] == nil,
           let path = processEnvironment["PATH"] {
            for directory in path.split(separator: ":").map(String.init) {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("ssh", isDirectory: false)
                    .path
                if candidate != "/usr/bin/ssh",
                   FileManager.default.isExecutableFile(atPath: candidate) {
                    processEnvironment["CMUX_CLI_TESTING"] = "1"
                    processEnvironment["CMUX_CLI_TEST_SSH_EXECUTABLE"] = candidate
                    break
                }
            }
        }
        process.environment = processEnvironment
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        // The blocking pipe reads and waitUntilExit() below run on dedicated
        // threads rather than DispatchQueue.global. Mock socket servers park
        // many threads in accept(); a starved global pool made this helper
        // report empty stdout and timedOut == true for children that had
        // already exited cleanly.
        let outputLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        let outputGroup = DispatchGroup()

        outputGroup.enter()
        Thread.detachNewThread {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stdoutData = data
            outputLock.unlock()
            outputGroup.leave()
        }

        outputGroup.enter()
        Thread.detachNewThread {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stderrData = data
            outputLock.unlock()
            outputGroup.leave()
        }

        let exitSignal = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + processTimeout(timeout)) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }
        _ = outputGroup.wait(timeout: .now() + 2)

        outputLock.lock()
        let finalStdoutData = stdoutData
        let finalStderrData = stderrData
        outputLock.unlock()
        let stdout = String(data: finalStdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: finalStderrData, encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
