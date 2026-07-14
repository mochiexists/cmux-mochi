import Foundation
import Darwin

@MainActor
final class AgentSessionProcessStore {
    var eventSink: (([String: Any]) -> Void)?
    var activeProviderSink: ((Bool) -> Void)? {
        didSet {
            emitActiveProviderStateIfNeeded()
        }
    }
    var hasActiveProviderSession: Bool {
        !sessions.isEmpty
    }
    private var sessions: [String: AgentSessionRunningSession] = [:]
    private var lastEmittedHasActiveProviderSession: Bool?
    private static let terminationEscalationInterval: DispatchTimeInterval = .seconds(3)

    func start(
        plan: AgentSessionLaunchPlan,
        workingDirectory: String?,
        providerSessionID: String? = nil
    ) async throws -> AgentSessionStartedSession {
        guard sessions.isEmpty else {
            throw AgentSessionBridgeError.sessionAlreadyRunning
        }
        let sessionId = UUID().uuidString
        let process = Process()
        let launchArguments = plan.arguments
        let launchEnvironment = plan.environment(overridingWorkingDirectory: workingDirectory)
        process.executableURL = plan.executableURL
        process.arguments = launchArguments
        process.environment = launchEnvironment
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .standardizedFileURL
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let inputWriter = AgentSessionInputWriter(fileHandle: stdin.fileHandleForWriting)
        let openCodeAuth = OpenCodeServerAuth(environment: launchEnvironment)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let running = AgentSessionRunningSession(
            sessionId: sessionId,
            providerID: plan.provider,
            executablePath: plan.executableURL.path,
            arguments: launchArguments,
            workingDirectory: workingDirectory,
            providerSessionID: providerSessionID,
            process: process,
            stdin: stdin,
            inputWriter: inputWriter,
            openCodeAuthorizationHeader: openCodeAuth?.authorizationHeader
        )
        if plan.provider == .codex {
            running.codexAppServerSession = CodexAppServerSession(
                workingDirectory: workingDirectory,
                existingThreadID: providerSessionID,
                writeData: { data in
                    try await inputWriter.write(data)
                },
                outputSink: { [weak self] stream, text in
                    self?.emitOutput(
                        sessionId: sessionId,
                        providerID: plan.provider,
                        stream: stream,
                        text: text
                    )
                },
                activitySink: { [weak self] activity in
                    self?.emitActivity(
                        sessionId: sessionId,
                        providerID: plan.provider,
                        activity: activity
                    )
                },
                turnCompleteSink: { [weak self] in
                    self?.emitTurnComplete(
                        sessionId: sessionId,
                        providerID: plan.provider
                    )
                },
                threadSnapshotSink: { [weak self, weak running] thread in
                    guard let running else { return }
                    self?.emitMirrorSnapshot(thread, session: running)
                },
                failureSink: { [weak self] _ in
                    self?.failSession(sessionId: sessionId, status: 1)
                }
            )
        }
        sessions[sessionId] = running

        running.stdoutReadTask = makeReadTask(stdout.fileHandleForReading, sessionId: sessionId, stream: "stdout")
        running.stderrReadTask = makeReadTask(stderr.fileHandleForReading, sessionId: sessionId, stream: "stderr")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self,
                      let session = self.sessions[sessionId] else {
                    return
                }
                session.pendingExitStatus = process.terminationStatus
                self.finishSessionIfExitedAndDrained(session)
            }
        }

        do {
            try process.run()
            emitActiveProviderStateIfNeeded()
            try await running.codexAppServerSession?.start()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            running.openCodeEventTask?.cancel()
            sessions.removeValue(forKey: sessionId)
            emitActiveProviderStateIfNeeded()
            throw error
        }

        if plan.provider != .opencode {
            emitStarted(session: running)
        }
        return AgentSessionStartedSession(sessionId: sessionId)
    }

    func writeLine(
        sessionId: String,
        permissionMode: AgentSessionPermissionMode = .standard,
        text: String
    ) async throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }

        switch session.providerID {
        case .codex:
            guard let codexAppServerSession = session.codexAppServerSession else {
                throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
            }
            try await codexAppServerSession.submit(text, permissionMode: permissionMode)
        case .claude:
            try await writeClaudeStreamJSON(text, to: session.inputWriter)
        case .opencode:
            try await postOpenCodePrompt(text, session: session)
        }
    }

    func stop(sessionId: String) throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }
        requestTermination(for: session)
    }

    func closeAll() {
        for session in sessions.values {
            requestTermination(for: session)
        }
    }

    private func makeReadTask(_ fileHandle: FileHandle, sessionId: String, stream: String) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let data: Data
                do {
                    data = try fileHandle.read(upToCount: 64 * 1024) ?? Data()
                } catch {
                    data = Data()
                }

                await self?.consumeOutputData(data, sessionId: sessionId, stream: stream)
                if data.isEmpty {
                    return
                }
            }
        }
    }

    private func consumeOutputData(_ data: Data, sessionId: String, stream: String) {
        guard let session = sessions[sessionId] else {
            return
        }
        if data.isEmpty {
            for text in session.flushBufferedOutput(stream: stream) {
                handleOutputLine(text, session: session, stream: stream)
            }
            session.drainedStreams.insert(stream)
            finishSessionIfExitedAndDrained(session)
            return
        }
        for text in session.appendOutputData(data, stream: stream) {
            handleOutputLine(text, session: session, stream: stream)
        }
    }

    private func finishSessionIfExitedAndDrained(_ session: AgentSessionRunningSession) {
        guard let status = session.pendingExitStatus,
              session.drainedStreams.isSuperset(of: ["stdout", "stderr"]),
              sessions[session.sessionId] === session else {
            return
        }
        sessions.removeValue(forKey: session.sessionId)
        cancelSessionTasks(session)
        emitActiveProviderStateIfNeeded()
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
    }

    private func failSession(sessionId: String, status: Int32) {
        guard let session = sessions.removeValue(forKey: sessionId) else {
            return
        }
        emitActiveProviderStateIfNeeded()
        cancelSessionTasks(session)
        requestTermination(for: session)
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
    }

    private func requestTermination(for session: AgentSessionRunningSession) {
        session.openCodeEventTask?.cancel()
        if session.process.isRunning {
            session.process.terminate()
        }
        installTerminationEscalationTimer(for: session)
    }

    private func installTerminationEscalationTimer(for session: AgentSessionRunningSession) {
        guard session.terminationEscalationTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + Self.terminationEscalationInterval,
            repeating: Self.terminationEscalationInterval
        )
        timer.setEventHandler { [weak self, session] in
            Task { @MainActor in
                if session.process.isRunning {
                    _ = kill(session.process.processIdentifier, SIGKILL)
                    return
                }
                guard let self,
                      self.sessions[session.sessionId] === session else {
                    timer.cancel()
                    return
                }
                guard session.pendingExitStatus != nil else {
                    return
                }
                session.drainedStreams.formUnion(["stdout", "stderr"])
                self.finishSessionIfExitedAndDrained(session)
            }
        }
        session.terminationEscalationTimer = timer
        timer.resume()
    }

    private func cancelSessionTasks(_ session: AgentSessionRunningSession) {
        session.codexAppServerSession?.stop()
        session.terminationEscalationTimer?.cancel()
        session.terminationEscalationTimer = nil
        session.stdoutReadTask?.cancel()
        session.stdoutReadTask = nil
        session.stderrReadTask?.cancel()
        session.stderrReadTask = nil
        Task {
            await session.inputWriter.close()
        }
        session.openCodeEventTask?.cancel()
        session.openCodeEventTask = nil
    }

    private func handleOutputLine(_ text: String, session: AgentSessionRunningSession, stream: String) {
        if session.providerID == .opencode {
            switch Self.openCodeProcessOutputDisposition(text: text, stream: stream) {
            case .serverURL(let baseURL):
                if session.openCodeBaseURL == nil {
                    session.openCodeBaseURL = baseURL
                    createOpenCodeSession(session)
                }
                return
            case .suppress:
                return
            case .emit:
                break
            }
        }

        if stream == "stdout",
           let codexAppServerSession = session.codexAppServerSession {
            codexAppServerSession.consumeStdout(text)
            return
        }

        if stream == "stdout",
           session.providerID == .claude {
            let completesTurn = session.claudeStreamJSONLineCompletesTurn(text)
            for delta in session.consumeClaudeStreamJSONLine(text) {
                emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: stream,
                    text: delta
                )
            }
            if completesTurn {
                emitTurnComplete(
                    sessionId: session.sessionId,
                    providerID: session.providerID
                )
            }
            return
        }

        emitOutput(
            sessionId: session.sessionId,
            providerID: session.providerID,
            stream: stream,
            text: text
        )
    }

    static func openCodeProcessOutputDisposition(text: String, stream: String) -> OpenCodeProcessOutputDisposition {
        if let baseURL = openCodeServerURL(from: text) {
            return .serverURL(baseURL)
        }
        if stream == "stdout" {
            return .suppress
        }
        return .emit
    }

    private static func openCodeServerURL(from text: String) -> URL? {
        let marker = "opencode server listening on "
        guard let range = text.range(of: marker) else { return nil }
        let rawURL = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        guard let url = rawURL.flatMap(URL.init(string:)),
              agentSessionIsLoopbackURL(url) else {
            return nil
        }
        return url
    }

    private func createOpenCodeSession(_ session: AgentSessionRunningSession) {
        guard !session.isOpenCodeSessionCreateInFlight,
              session.openCodeSessionID == nil,
              let baseURL = session.openCodeBaseURL else {
            return
        }
        session.isOpenCodeSessionCreateInFlight = true
        Task { @MainActor in
            do {
                let response = try await self.postJSON(
                    to: self.openCodeURL(baseURL: baseURL, path: "session", workingDirectory: session.workingDirectory),
                    body: [:],
                    authorizationHeader: session.openCodeAuthorizationHeader
                )
                guard let id = response["id"] as? String, !id.isEmpty else {
                    throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
                }
                guard self.sessions[session.sessionId] === session else { return }
                session.openCodeSessionID = id
                session.isOpenCodeSessionCreateInFlight = false
                self.startOpenCodeEventStream(session)
                self.emitStarted(session: session)
            } catch {
                session.isOpenCodeSessionCreateInFlight = false
                guard let removedSession = self.sessions.removeValue(forKey: session.sessionId),
                      removedSession === session else {
                    return
                }
                self.emitActiveProviderStateIfNeeded()
                self.cancelSessionTasks(session)
                self.requestTermination(for: session)
                let message = (error as? AgentSessionBridgeError)?.localizedDescription
                    ?? String(
                        localized: "agentSession.opencode.error.sessionCreateFailed",
                        defaultValue: "OpenCode session could not be created."
                    )
                self.emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: "stderr",
                    text: "\(message)\n"
                )
                self.emitExit(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    status: 1
                )
            }
        }
    }

    private func postOpenCodePrompt(_ text: String, session: AgentSessionRunningSession) async throws {
        guard let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
        }
        let url = openCodeURL(
            baseURL: baseURL,
            path: "session/\(openCodeSessionID)/prompt_async",
            workingDirectory: session.workingDirectory
        )
        _ = try await postJSON(
            to: url,
            body: [
                "parts": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ],
            authorizationHeader: session.openCodeAuthorizationHeader
        )
    }

    private func startOpenCodeEventStream(_ session: AgentSessionRunningSession) {
        guard session.openCodeEventTask == nil,
              let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            return
        }
        let url = openCodeURL(baseURL: baseURL, path: "event", workingDirectory: session.workingDirectory)
        let authorizationHeader = session.openCodeAuthorizationHeader
        let sessionId = session.sessionId

        session.openCodeEventTask = Task.detached(priority: .utility) { [weak self] in
            await Self.consumeOpenCodeEventStream(
                sessionId: sessionId,
                openCodeSessionID: openCodeSessionID,
                url: url,
                authorizationHeader: authorizationHeader,
                handleEvent: { event in
                    await self?.handleOpenCodeEvent(
                        event,
                        sessionId: sessionId,
                        openCodeSessionID: openCodeSessionID
                    )
                },
                shouldFailOnEOF: {
                    await self?.openCodeEventStreamEOFRequiresFailure(sessionId: sessionId) ?? false
                },
                failStream: {
                    await self?.failOpenCodeEventStream(
                        sessionId: sessionId,
                        openCodeSessionID: openCodeSessionID
                    )
                }
            )
        }
    }

    nonisolated private static func consumeOpenCodeEventStream(
        sessionId: String,
        openCodeSessionID: String,
        url: URL,
        authorizationHeader: String?,
        handleEvent: ([String: Any]) async -> Void,
        shouldFailOnEOF: () async -> Bool,
        failStream: () async -> Void
    ) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.opencode.displayName)
            }

            var parser = OpenCodeEventStreamParser()
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                for event in parser.consumeLine(line) {
                    await handleEvent(event)
                }
            }
            for event in parser.flush() {
                await handleEvent(event)
            }
            guard !Task.isCancelled,
                  await shouldFailOnEOF() else {
                return
            }
            await failStream()
        } catch {
            guard !Task.isCancelled else { return }
#if DEBUG
            cmuxDebugLog("agentSession.opencode.eventStream.failed error=\(error.localizedDescription)")
#endif
            await failStream()
        }
    }

    private func openCodeEventStreamEOFRequiresFailure(sessionId: String) -> Bool {
        Self.openCodeEventStreamEOFRequiresFailure(
            isCancelled: false,
            processIsRunning: sessions[sessionId]?.process.isRunning == true
        )
    }

    static func openCodeEventStreamEOFRequiresFailure(isCancelled: Bool, processIsRunning: Bool) -> Bool {
        !isCancelled && processIsRunning
    }

    private func failOpenCodeEventStream(sessionId: String, openCodeSessionID: String) {
        guard let session = sessions[sessionId],
              session.openCodeSessionID == openCodeSessionID else {
            return
        }
        let message = String(
            localized: "agentSession.opencode.error.eventStreamFailed",
            defaultValue: "OpenCode event stream disconnected."
        )
        emitOutput(
            sessionId: session.sessionId,
            providerID: session.providerID,
            stream: "stderr",
            text: "\(message)\n"
        )
        failSession(sessionId: sessionId, status: 1)
    }

    private func handleOpenCodeEvent(_ event: [String: Any], sessionId: String, openCodeSessionID: String) {
        guard let session = sessions[sessionId],
              session.openCodeSessionID == openCodeSessionID else {
            return
        }

        let completesTurn = session.openCodeEventCompletesAssistantTurn(
            event,
            openCodeSessionID: openCodeSessionID
        )
        for output in session.consumeOpenCodeEvent(event, openCodeSessionID: openCodeSessionID) {
            emitOutput(
                sessionId: session.sessionId,
                providerID: session.providerID,
                stream: "stdout",
                text: output
            )
        }
        if completesTurn {
            emitTurnComplete(
                sessionId: session.sessionId,
                providerID: session.providerID
            )
        }
    }

    private func openCodeURL(baseURL: URL, path: String, workingDirectory: String?) -> URL {
        let url = path.split(separator: "/").reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let workingDirectory {
            components?.queryItems = [URLQueryItem(name: "directory", value: workingDirectory)]
        }
        return components?.url ?? url
    }

    private func postJSON(
        to url: URL,
        body: [String: Any],
        authorizationHeader: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw AgentSessionBridgeError.providerNotReady("OpenCode")
        }
        guard !data.isEmpty else { return [:] }
        let decoded = try JSONSerialization.jsonObject(with: data, options: [])
        return decoded as? [String: Any] ?? [:]
    }

    private func writeClaudeStreamJSON(_ text: String, to inputWriter: AgentSessionInputWriter) async throws {
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: message, options: [])
        data.append(0x0A)
        try await inputWriter.write(data)
    }

    private func emitStarted(session: AgentSessionRunningSession) {
        var event: [String: Any] = [
            "type": "provider.started",
            "sessionId": session.sessionId,
            "providerId": session.providerID.rawValue,
            "executablePath": session.executablePath,
            "arguments": session.arguments
        ]
        if let providerSessionID = session.providerSessionID {
            event["providerSessionId"] = providerSessionID
        }
        eventSink?(event)
    }

    private func emitOutput(
        sessionId: String,
        providerID: AgentSessionProviderID,
        stream: String,
        text: String
    ) {
        eventSink?([
            "type": "provider.output",
            "sessionId": sessionId,
            "providerId": providerID.rawValue,
            "stream": stream,
            "text": text
        ])
    }

    private func emitActivity(
        sessionId: String,
        providerID: AgentSessionProviderID,
        activity: [String: Any]
    ) {
        var event = activity
        event["type"] = "provider.activity"
        event["sessionId"] = sessionId
        event["providerId"] = providerID.rawValue
        eventSink?(event)
    }

    private func emitTurnComplete(
        sessionId: String,
        providerID: AgentSessionProviderID
    ) {
        eventSink?([
            "type": "provider.turnComplete",
            "sessionId": sessionId,
            "providerId": providerID.rawValue
        ])
    }

    private func emitMirrorSnapshot(_ thread: [String: Any], session: AgentSessionRunningSession) {
        let providerSessionID = (thread["id"] as? String) ?? session.providerSessionID ?? ""
        let turns = thread["turns"] as? [[String: Any]] ?? []
        eventSink?([
            "type": "provider.transcript",
            "sessionId": session.sessionId,
            "providerId": session.providerID.rawValue,
            "providerSessionId": providerSessionID,
            "entries": Self.mirrorTranscriptEntries(turns: turns, runtimeSessionID: session.sessionId)
        ])

        let terminalTurns = turns.compactMap { turn -> (String, String)? in
            guard let id = turn["id"] as? String,
                  let status = turn["status"] as? String,
                  Self.isTerminalTurnStatus(status) else {
                return nil
            }
            return (id, status)
        }
        let terminalIDs = Set(terminalTurns.map(\.0))
        if session.didReceiveInitialMirrorSnapshot {
            for (turnID, status) in terminalTurns where !session.knownMirrorTerminalTurnIDs.contains(turnID) {
                eventSink?([
                    "type": "provider.turnComplete",
                    "sessionId": session.sessionId,
                    "providerId": session.providerID.rawValue,
                    "providerSessionId": providerSessionID,
                    "turnId": turnID,
                    "status": status
                ])
            }
        } else {
            session.didReceiveInitialMirrorSnapshot = true
        }
        session.knownMirrorTerminalTurnIDs.formUnion(terminalIDs)
    }

    static func isTerminalTurnStatus(_ status: String) -> Bool {
        switch status.lowercased() {
        // ThreadStore normalizes a turn that is still active in another Codex
        // process to `interrupted` when read by this observer. Treating that as
        // terminal would publish a false completion while the turn is running.
        case "completed", "failed", "cancelled", "canceled":
            return true
        default:
            return false
        }
    }

    private static func mirrorTranscriptEntries(
        turns: [[String: Any]],
        runtimeSessionID: String
    ) -> [[String: Any]] {
        var entries: [[String: Any]] = []
        for turn in turns {
            let isComplete = (turn["status"] as? String).map(isTerminalTurnStatus) ?? false
            for item in turn["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String,
                      let type = item["type"] as? String else {
                    continue
                }
                switch type {
                case "userMessage":
                    let text = userMessageText(item["content"])
                    if !text.isEmpty {
                        entries.append(["id": id, "role": "user", "text": text])
                    }
                case "agentMessage":
                    guard let text = item["text"] as? String, !text.isEmpty else { continue }
                    entries.append([
                        "id": id,
                        "role": "assistant",
                        "text": text,
                        "sessionId": runtimeSessionID,
                        "isComplete": isComplete
                    ])
                case "commandExecution":
                    let command = item["command"] as? String ?? "Command"
                    var entry: [String: Any] = [
                        "id": id,
                        "role": "activity",
                        "text": command,
                        "sessionId": runtimeSessionID,
                        "activityId": id,
                        "activityKind": "command",
                        "activityStatus": normalizedActivityStatus(item["status"] as? String)
                    ]
                    if let output = item["aggregatedOutput"] as? String, !output.isEmpty {
                        entry["output"] = output
                    }
                    entries.append(entry)
                default:
                    continue
                }
            }
        }
        return Array(entries.suffix(200))
    }

    private static func userMessageText(_ content: Any?) -> String {
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part in
            for key in ["text", "prompt"] {
                if let value = part[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }.joined(separator: "\n")
    }

    private static func normalizedActivityStatus(_ status: String?) -> String {
        switch status?.lowercased() {
        case "completed", "success": return "completed"
        case "failed", "error": return "failed"
        case "interrupted", "stopped", "cancelled", "canceled": return "stopped"
        default: return "inProgress"
        }
    }

    private func emitExit(
        sessionId: String,
        providerID: AgentSessionProviderID,
        status: Int32
    ) {
        eventSink?([
            "type": "provider.exit",
            "sessionId": sessionId,
            "providerId": providerID.rawValue,
            "status": status
        ])
    }

    private func emitActiveProviderStateIfNeeded() {
        let hasActiveProviderSession = self.hasActiveProviderSession
        guard lastEmittedHasActiveProviderSession != hasActiveProviderSession else { return }
        lastEmittedHasActiveProviderSession = hasActiveProviderSession
        activeProviderSink?(hasActiveProviderSession)
    }
}
