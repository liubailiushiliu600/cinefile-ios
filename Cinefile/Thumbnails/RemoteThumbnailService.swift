import CryptoKit
import Foundation
import MobileVLCKit
import UIKit

/// Thumbnails for files on a paired peer's SMB share.
///
/// AVFoundation cannot open `smb://`, so this service briefly plays the file
/// through VLC on a nearly invisible surface and saves one frame
/// (`saveVideoSnapshot`). It seeks straight to the capture point
/// (`:start-time=3`) and disables audio, which is the closest VLC gets to
/// Infuse-style single-frame decoding. Two captures run in parallel so a folder
/// fills in about twice as fast; results are cached on disk.
@MainActor
final class RemoteThumbnailService {
    static let shared = RemoteThumbnailService()

    private struct Job {
        let entry: Entry
        let url: URL
        let completion: (UIImage?) -> Void
    }

    private final class Session {
        let id = UUID()
        let job: Job
        let player: VLCMediaPlayer
        let surface: UIView
        var timer: Timer?
        let deadline: Date

        init(job: Job, player: VLCMediaPlayer, surface: UIView, deadline: Date) {
            self.job = job
            self.player = player
            self.surface = surface
            self.deadline = deadline
        }
    }

    private var queue: [Job] = []
    private var sessions: [UUID: Session] = [:]
    private let maxConcurrent = 2
    private let cacheDirectory: URL
    /// Caps parallel FFmpeg decodes so a folder does not spawn 10 at once.
    private static let ffmpegGate = DispatchSemaphore(value: 2)

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("Cinefile/RemoteThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func thumbnail(for entry: Entry, client: SMBClient, access: SMBAccess) async -> UIImage? {
        guard let path = entry.remotePath, let url = access.playbackURL(relativePath: path) else {
            return nil
        }

        let destination = cacheDirectory.appendingPathComponent(Self.key(for: entry) + ".jpg")
        if let data = try? Data(contentsOf: destination), let image = UIImage(data: data) {
            return image
        }

        // Fast path: FFmpeg decodes exactly one frame (Infuse-style).
        let extracted = await Task.detached(priority: .utility) {
            Self.ffmpegGate.wait()
            defer { Self.ffmpegGate.signal() }
            return client.extractThumbnail(relativePath: path, fileSize: entry.size, at: 3.0)
        }.value

        if let extracted {
            if let data = extracted.jpegData(compressionQuality: 0.72) {
                try? data.write(to: destination, options: .atomic)
            }
            return extracted
        }

        // Fallback: VLC play-and-snapshot queue.
        return await withCheckedContinuation { continuation in
            // Do not let fast scrolling pile up hundreds of jobs.
            if queue.count >= 60 {
                continuation.resume(returning: nil)
                return
            }
            queue.append(
                Job(entry: entry, url: url) { image in
                    continuation.resume(returning: image)
                }
            )
            pump()
        }
    }

    // MARK: - Queue

    private func pump() {
        guard !PlaybackActivity.shared.isPlaying else { return }
        while sessions.count < maxConcurrent, !queue.isEmpty {
            start(queue.removeFirst())
        }
    }

    /// Stop every in-flight capture and put the jobs back at the head.
    func pauseForPlayback() {
        guard !sessions.isEmpty else { return }
        let jobs = sessions.values.map(\.job)
        for session in sessions.values {
            session.timer?.invalidate()
            session.timer = nil
            session.player.stop()
            session.surface.removeFromSuperview()
        }
        sessions.removeAll()
        queue.insert(contentsOf: jobs, at: 0)
    }

    func resumeAfterPlayback() {
        pump()
    }

    private func start(_ job: Job) {
        let player = VLCMediaPlayer()
        let view = makeSurface()
        player.drawable = view

        let media = VLCMedia(url: job.url)
        media.addOption(":start-time=3")
        media.addOption(":no-audio")
        player.media = media
        player.play()

        let session = Session(
            job: job,
            player: player,
            surface: view,
            deadline: Date().addingTimeInterval(8)
        )
        sessions[session.id] = session

        session.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick(session.id)
            }
        }
    }

    private func tick(_ id: UUID) {
        guard let session = sessions[id] else { return }
        let seconds = Double(session.player.time.intValue) / 1000.0
        if seconds >= 3.4 || Date() > session.deadline {
            finish(session)
        }
    }

    private func finish(_ session: Session) {
        session.timer?.invalidate()
        session.timer = nil

        let job = session.job
        let destination = cacheDirectory.appendingPathComponent(Self.key(for: job.entry) + ".jpg")
        try? FileManager.default.removeItem(at: destination)
        session.player.saveVideoSnapshot(at: destination.path, withWidth: 640, andHeight: 360)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let image = (try? Data(contentsOf: destination)).flatMap { UIImage(data: $0) }
            session.player.stop()
            session.surface.removeFromSuperview()
            self.sessions.removeValue(forKey: session.id)
            job.completion(image)
            self.pump()
        }
    }

    // MARK: - Helpers

    private func makeSurface() -> UIView {
        // Must sit inside the window (not off-screen) or VLC will not create a
        // video output; alpha 0.02 keeps it invisible to the user.
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        view.backgroundColor = .black
        view.alpha = 0.02
        view.isUserInteractionEnabled = false
        if let window = Self.keyWindow() {
            window.addSubview(view)
        }
        return view
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    static func key(for entry: Entry) -> String {
        let material = "\(entry.id)|\(entry.size)|remote-thumb-v1"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
