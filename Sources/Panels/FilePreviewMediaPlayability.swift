/// Whether a file can be handed to `AVPlayerView` without tripping AVKit's failure UI.
enum FilePreviewMediaPlayability: Equatable, Sendable {
    /// AVFoundation reports at least one decodable track, so a player can be attached.
    case playable
    /// The file cannot be decoded; the preview shows its own message instead of a player.
    case unsupported
}
