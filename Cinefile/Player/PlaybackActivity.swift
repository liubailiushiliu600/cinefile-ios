import Foundation

/// Tracks whether a video is currently playing.
///
/// Thumbnail generation (which decodes remote files through VLC) pauses while
/// playback is active, so it never competes for SMB bandwidth or decoder slots
/// with the film the user is actually watching.
@MainActor
final class PlaybackActivity {
    static let shared = PlaybackActivity()

    private(set) var isPlaying = false

    private init() {}

    func begin() {
        guard !isPlaying else { return }
        isPlaying = true
        RemoteThumbnailService.shared.pauseForPlayback()
    }

    func end() {
        guard isPlaying else { return }
        isPlaying = false
        RemoteThumbnailService.shared.resumeAfterPlayback()
    }
}
