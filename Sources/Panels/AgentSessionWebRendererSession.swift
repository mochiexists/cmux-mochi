import AppKit
import Foundation

@MainActor
final class AgentSessionWebRendererSession {
    private let ownedCoordinator = AgentSessionWebRendererCoordinator()
    private let runtimeModel = AgentSessionRuntimeModel()

    init() {
        ownedCoordinator.onProviderEvent = { [weak runtimeModel] event in
            runtimeModel?.consume(event)
        }
    }
    var onHasActiveProviderChanged: ((Bool) -> Void)? {
        didSet {
            ownedCoordinator.onHasActiveProviderChanged = onHasActiveProviderChanged
        }
    }
    var onProviderIDChanged: ((AgentSessionProviderID) -> Void)? {
        didSet {
            ownedCoordinator.onProviderIDChanged = onProviderIDChanged
        }
    }

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID,
        providerSessionID: String? = nil,
        workingDirectory: String?,
        restoredFromSession: Bool,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) -> AgentSessionWebRendererCoordinator {
        runtimeModel.bind(providerID: initialProviderID, providerSessionID: providerSessionID)
        ownedCoordinator.bind(
            panelId: panelId,
            workspaceId: workspaceId,
            rendererKind: rendererKind,
            initialProviderID: initialProviderID,
            providerSessionID: providerSessionID,
            workingDirectory: workingDirectory,
            restoredFromSession: restoredFromSession,
            theme: theme,
            isFocused: isFocused
        )
        return ownedCoordinator
    }

    /// View to composite into workspace-level captures; nil until the web renderer mounts.
    var captureView: NSView? {
        ownedCoordinator.webView
    }

    func captureVisibleSnapshot(completion: @escaping (Result<NSImage, Error>) -> Void) {
        ownedCoordinator.captureVisibleSnapshot(completion: completion)
    }

    func transcriptSnapshot() -> AgentSessionTranscriptSnapshot {
        runtimeModel.snapshot()
    }

    func consumeProviderEvent(_ event: [String: Any]) {
        runtimeModel.consume(event)
    }

    func focus() {
        ownedCoordinator.focus()
    }

    func unfocus() {
        ownedCoordinator.unfocus()
    }

    func close() {
        ownedCoordinator.close()
    }
}

@MainActor
struct AgentSessionTranscriptSnapshot {
    let text: String
    let entries: [[String: Any]]
    let providerID: String
    let runtimeSessionID: String?
    let providerSessionID: String?
    let turnID: String?
    let turnStatus: String?
}

@MainActor
private final class AgentSessionRuntimeModel {
    private var providerID = AgentSessionProviderID.codex.rawValue
    private var runtimeSessionID: String?
    private var providerSessionID: String?
    private var turnID: String?
    private var turnStatus: String?
    private var entries: [[String: Any]] = []

    func bind(providerID: AgentSessionProviderID, providerSessionID: String?) {
        self.providerID = providerID.rawValue
        self.providerSessionID = providerSessionID
    }

    func consume(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if let providerID = event["providerId"] as? String {
            self.providerID = providerID
        }
        if let runtimeSessionID = event["sessionId"] as? String {
            self.runtimeSessionID = runtimeSessionID
        }
        if let providerSessionID = event["providerSessionId"] as? String {
            self.providerSessionID = providerSessionID
        }
        switch type {
        case "provider.transcript":
            entries = Array((event["entries"] as? [[String: Any]] ?? []).suffix(200))
        case "provider.output":
            guard event["stream"] as? String == "stdout",
                  let text = event["text"] as? String,
                  !text.isEmpty else { return }
            appendAssistantDelta(text)
        case "provider.turnComplete":
            turnID = event["turnId"] as? String
            turnStatus = event["status"] as? String ?? "completed"
            markAssistantComplete()
        case "provider.exit":
            markAssistantComplete()
        default:
            break
        }
    }

    func snapshot() -> AgentSessionTranscriptSnapshot {
        AgentSessionTranscriptSnapshot(
            text: plainText(),
            entries: entries,
            providerID: providerID,
            runtimeSessionID: runtimeSessionID,
            providerSessionID: providerSessionID,
            turnID: turnID,
            turnStatus: turnStatus
        )
    }

    private func appendAssistantDelta(_ delta: String) {
        if let last = entries.indices.last,
           entries[last]["role"] as? String == "assistant",
           entries[last]["isComplete"] as? Bool != true {
            let previous = entries[last]["text"] as? String ?? ""
            entries[last]["text"] = previous + delta
            return
        }
        entries.append([
            "id": UUID().uuidString,
            "role": "assistant",
            "text": delta,
            "sessionId": runtimeSessionID ?? "",
            "isComplete": false
        ])
        entries = Array(entries.suffix(200))
    }

    private func markAssistantComplete() {
        for index in entries.indices where entries[index]["role"] as? String == "assistant" {
            entries[index]["isComplete"] = true
        }
    }

    private func plainText() -> String {
        entries.compactMap { entry in
            guard let text = entry["text"] as? String, !text.isEmpty else { return nil }
            switch entry["role"] as? String {
            case "user": return "User: \(text)"
            case "assistant": return "Assistant: \(text)"
            case "activity": return "Activity: \(text)"
            default: return text
            }
        }.joined(separator: "\n\n")
    }
}
