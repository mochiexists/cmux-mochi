import CMUXMobileCore
import CmuxMobileTransport
import Foundation

actor MobileHostSerializedTransportWriter {
    private let transport: any CmxByteTransport
    private var sending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(transport: any CmxByteTransport) {
        self.transport = transport
    }

    func send(_ data: Data) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await transport.send(data)
    }

    private func acquire() async {
        if !sending {
            sending = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            sending = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
