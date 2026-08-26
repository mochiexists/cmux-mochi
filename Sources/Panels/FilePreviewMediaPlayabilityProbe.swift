import AVFoundation

/// Preflights a media file before the preview attaches it to an `AVPlayerView`.
///
/// AVKit swaps in `AVUnsupportedContentIndicatorView` when a player item transitions to
/// `.failed`, and on macOS 26 building that view raises an `NSLayoutConstraint` assertion
/// that aborts the process. The exception is thrown inside AVKit's own KVO handler, so
/// nothing on the Swift side can intercept it; the only defense is to resolve playability
/// first and never hand an undecodable file to the player.
struct FilePreviewMediaPlayabilityProbe: Sendable {
    @concurrent
    func playability(of url: URL) async -> FilePreviewMediaPlayability {
        await playability(of: AVURLAsset(url: url))
    }

    @concurrent
    func playability(of asset: AVURLAsset) async -> FilePreviewMediaPlayability {
        do {
            guard try await asset.load(.isPlayable) else { return .unsupported }
            for track in try await asset.load(.tracks) {
                let (isPlayable, isDecodable) = try await track.load(.isPlayable, .isDecodable)
                if isPlayable, isDecodable {
                    return .playable
                }
            }
            return .unsupported
        } catch {
            return .unsupported
        }
    }
}
