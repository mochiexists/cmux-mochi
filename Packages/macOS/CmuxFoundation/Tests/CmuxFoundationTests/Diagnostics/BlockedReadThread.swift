import Darwin
import Foundation

/// A thread that publishes its Mach port and then blocks in `read(2)` until
/// the test writes to the pipe, standing in for a main thread stuck in a
/// system call.
final class BlockedReadThread: Sendable {
    private let readDescriptor: Int32
    private let published: AsyncStream<thread_act_t>
    private let publish: AsyncStream<thread_act_t>.Continuation

    init(readDescriptor: Int32) {
        self.readDescriptor = readDescriptor
        (published, publish) = AsyncStream.makeStream(of: thread_act_t.self)
    }

    func start() {
        let readDescriptor = readDescriptor
        let publish = publish
        Thread.detachNewThread {
            publish.yield(mach_thread_self())
            publish.finish()
            var byte: UInt8 = 0
            _ = read(readDescriptor, &byte, 1)
        }
    }

    func port() async throws -> thread_act_t {
        for await port in published {
            return port
        }
        throw CancellationError()
    }
}
