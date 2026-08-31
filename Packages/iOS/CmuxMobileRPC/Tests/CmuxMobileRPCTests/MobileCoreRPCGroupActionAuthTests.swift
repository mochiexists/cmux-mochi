import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCWorkspaceMutationAuthTests {
    @Test func workspaceMoveUsesTransportAdmissionOnly() async throws {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.move",
            params: [
                "workspace_id": "workspace-main",
                "before_workspace_id": "workspace-next",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.move")
        #expect(frame.hasAuth == false)
    }

    @Test func workspaceGroupActionUsesTransportAdmissionOnly() async throws {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.group.action",
            params: [
                "group_id": "group-main",
                "action": "rename",
                "title": "Project Alpha",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.group.action")
        #expect(frame.hasAuth == false)
    }

    @Test func macWideWorkspaceGroupActionUsesTransportAdmissionOnly() async throws {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.group.action",
            params: [
                "group_id": "group-main",
                "action": "rename",
                "title": "Project Alpha",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.group.action")
        #expect(frame.hasAuth == false)
    }

    @Test func workspaceGroupCreateUsesTransportAdmissionOnly() async throws {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.group.create",
            params: [
                "title": "Ops",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.group.create")
        #expect(frame.hasAuth == false)
    }
}
