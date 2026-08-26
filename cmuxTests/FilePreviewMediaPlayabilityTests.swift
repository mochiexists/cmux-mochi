import AVFAudio
import AVKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct FilePreviewMediaPlayabilityTests {
    @Test("The probe rejects media AVFoundation cannot decode")
    func probeRejectsUndecodableMedia() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-media-probe-broken-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(repeating: 0x41, count: 4096).write(to: fileURL)

        let probe = FilePreviewMediaPlayabilityProbe()
        #expect(await probe.playability(of: fileURL) == .unsupported)
    }

    @Test("The probe rejects a file that is not there")
    func probeRejectsMissingFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-media-probe-missing-\(UUID().uuidString).wav")

        let probe = FilePreviewMediaPlayabilityProbe()
        #expect(await probe.playability(of: fileURL) == .unsupported)
    }

    @Test("The probe accepts decodable media")
    func probeAcceptsDecodableMedia() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-media-probe-playable-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try writeSilentAudio(to: fileURL)

        let probe = FilePreviewMediaPlayabilityProbe()
        #expect(await probe.playability(of: fileURL) == .playable)
    }

    @Test("Media that stops being decodable is pulled away from the player")
    func undecodableReloadDetachesPlayer() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-media-playability-broken-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try writeSilentAudio(to: fileURL)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        #expect(panel.previewMode == .media)

        await panel.reloadFromDisk().value
        #expect(panel.mediaPlayability == .playable)

        let session = panel.nativeViewSessions.media
        let view = session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        #expect(view.player != nil)

        let revisionBeforeBreaking = panel.previewRevision
        try Data(repeating: 0x41, count: 4096).write(to: fileURL)
        await panel.reloadFromDisk().value

        #expect(panel.mediaPlayability == .unsupported)
        #expect(view.player == nil)
        #expect(panel.previewRevision == revisionBeforeBreaking)
    }

    @Test("Decodable media keeps reaching the player across reloads")
    func decodableReloadKeepsPlayer() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-media-playability-playable-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try writeSilentAudio(to: fileURL)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        #expect(panel.previewMode == .media)

        await panel.reloadFromDisk().value
        let revisionAfterFirstReload = panel.previewRevision
        #expect(panel.mediaPlayability == .playable)

        try writeSilentAudio(to: fileURL, durationSeconds: 2)
        await panel.reloadFromDisk().value

        #expect(panel.mediaPlayability == .playable)
        #expect(panel.previewRevision > revisionAfterFirstReload)

        let session = panel.nativeViewSessions.media
        let view = session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        #expect(view.player?.currentItem != nil)
    }

    @Test("A deleted media file clears the playability verdict")
    func deletedMediaClearsPlayability() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-media-playability-deleted-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try writeSilentAudio(to: fileURL)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }

        await panel.reloadFromDisk().value
        #expect(panel.mediaPlayability == .playable)

        try FileManager.default.removeItem(at: fileURL)
        await panel.reloadFromDisk().value

        #expect(panel.isFileUnavailable)
        #expect(panel.mediaPlayability == nil)
    }

    private func writeSilentAudio(
        to url: URL,
        durationSeconds: Double = 1
    ) throws {
        let sampleRate = 8_000.0
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            )
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        )
        buffer.frameLength = frameCount
        buffer.floatChannelData?[0].update(
            repeating: 0,
            count: Int(frameCount)
        )
        try file.write(from: buffer)
    }
}
