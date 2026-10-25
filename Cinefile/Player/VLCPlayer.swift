import Foundation
import MobileVLCKit

/// One selectable track (audio or subtitle).
struct VLCTrack: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// Thin wrapper around MobileVLCKit.
///
/// VLC is only used as the decoding/demuxing engine (mkv, rmvb, avi, ts, webm,
/// H.264/HEVC/AV1/RealVideo ...). Every piece of player behaviour — the
/// surface, transport controls, seeking, track menus, auto-hiding chrome — is
/// implemented here and in PlayerScreen.
final class VLCPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var position: Float = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var audioTracks: [VLCTrack] = []
    @Published var subtitleTracks: [VLCTrack] = []
    @Published var currentAudio: Int32 = -1
    @Published var currentSubtitle: Int32 = -1
    @Published var isEnded = false
    @Published var errorText: String?
    @Published var volume: Int32 = 100
    @Published var isMuted = false

    let player = VLCMediaPlayer()
    private var isSeeking = false

    override init() {
        super.init()
        player.delegate = self
    }

    // MARK: - Transport

    func open(_ url: URL) {
        errorText = nil
        isEnded = false
        let media = VLCMedia(url: url)
        player.media = media
        player.play()
        player.audio?.volume = volume
        player.audio?.isMuted = isMuted
    }

    func togglePlay() {
        if player.isPlaying {
            player.pause()
        } else {
            if isEnded {
                isEnded = false
                player.position = 0
            }
            player.play()
        }
        isPlaying = player.isPlaying
    }

    func skip(_ seconds: Double) {
        let target = max(0, currentTime + seconds)
        if duration > 0 {
            player.time = VLCTime(int: Int32(min(target, duration) * 1000))
        } else {
            player.time = VLCTime(int: Int32(target * 1000))
        }
    }

    func beginSeeking() {
        isSeeking = true
    }

    func endSeeking(_ fraction: Float) {
        player.position = min(max(fraction, 0), 1)
        isSeeking = false
    }

    func stop() {
        player.stop()
    }

    // MARK: - Audio

    func setVolume(_ value: Int32) {
        volume = min(max(value, 0), 200)
        player.audio?.volume = volume
        if volume > 0 && isMuted {
            isMuted = false
            player.audio?.isMuted = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.audio?.isMuted = isMuted
    }

    // MARK: - Tracks

    func selectAudio(_ index: Int32) {
        player.currentAudioTrackIndex = index
        currentAudio = index
    }

    func selectSubtitle(_ index: Int32) {
        player.currentVideoSubTitleIndex = index
        currentSubtitle = index
    }

    func refreshTracks() {
        let audioIndexes = (player.audioTrackIndexes as? [NSNumber]) ?? []
        let audioNames = (player.audioTrackNames as? [String]) ?? []
        var audio: [VLCTrack] = []
        for (offset, number) in audioIndexes.enumerated() {
            let name = offset < audioNames.count ? audioNames[offset] : "音轨 \(offset + 1)"
            audio.append(VLCTrack(id: number.int32Value, name: name))
        }
        audioTracks = audio
        currentAudio = player.currentAudioTrackIndex

        let subtitleIndexes = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        let subtitleNames = (player.videoSubTitlesNames as? [String]) ?? []
        var subtitles: [VLCTrack] = []
        for (offset, number) in subtitleIndexes.enumerated() {
            let name = offset < subtitleNames.count ? subtitleNames[offset] : "字幕 \(offset + 1)"
            subtitles.append(VLCTrack(id: number.int32Value, name: name))
        }
        subtitleTracks = subtitles
        currentSubtitle = player.currentVideoSubTitleIndex
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCPlayer: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPlaying = self.player.isPlaying
            switch self.player.state {
            case .playing:
                self.refreshTracks()
            case .ended:
                self.isEnded = true
                self.isPlaying = false
            case .error:
                self.errorText = "无法播放这个文件：解码失败或文件已损坏。"
            default:
                break
            }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let time = Double(self.player.time?.intValue ?? 0) / 1000.0
            let lengthTime: VLCTime? = self.player.media?.length
            let length = Double(lengthTime?.intValue ?? 0) / 1000.0
            if length > 0 {
                self.duration = length
            }
            if !self.isSeeking {
                self.currentTime = max(0, time)
                self.position = length > 0 ? Float(max(0, time) / length) : 0
            }
        }
    }
}
