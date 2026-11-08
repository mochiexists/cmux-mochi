import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite
struct ThreadProgramCounterSymbolReaderTests {
    @Test
    func readerNamesTheCallABlockedThreadIsParkedIn() async throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        let readEnd = descriptors[0]
        let writeEnd = descriptors[1]
        defer {
            close(readEnd)
            close(writeEnd)
        }
        let blockedThread = BlockedReadThread(readDescriptor: readEnd)
        blockedThread.start()
        let reader = ThreadProgramCounterSymbolReader(thread: try await blockedThread.port())

        var symbol: String?
        for _ in 0..<200 {
            symbol = reader.currentSymbol()
            if symbol?.contains("read") == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(symbol?.contains("read") == true)
        var byte: UInt8 = 0
        _ = write(writeEnd, &byte, 1)
    }
}
