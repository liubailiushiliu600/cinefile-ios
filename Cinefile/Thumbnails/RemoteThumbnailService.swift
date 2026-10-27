import CryptoKit
import Foundation
import MobileVLCKit
import UIKit

/// Thumbnails for files on a paired peer's SMB share.
///
/// AVFoundation cannot open `smb://`, so this service briefly plays the file
/// through VLC on a nearly invisible surface and saves one frame
/// (`saveVideoSnapshot`). Jobs run one at a time, results are cached on disk
/// keyed by entry id + size, so a folder only pays the cost once.
@MainActor
final class RemoteThumbnailService {
    static let shared = RemoteThumbnailService()

    private struct Job {
        let entry: Entry
        let url: URL
        let completion: (UIImage?) -> Void
    }

    private var queue: [Job] = []
    private var busy = false
    private var activeJob: Job?
    private var player: VLCMediaPlayer?
    private var surface: UIView?
    private var timer: Timer?
    private var deadline: Date?
    private let cacheDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("Cinefile/RemoteThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func thumbnail(for entry: Entry, access: SMBAccess) async -> UIImage? {
        guard let path = entry.remotePath, let url = access.playbackURL(relativePath: path) else {
            return nil
        }

        let destination = cacheDirectory.appendingPathComponent(Self.key(for: entry) + ".jpg")
        if let data = try? Data(contentsOf: destination), let image = UIImage(data: data) {
            return image
        }

        return await withCheckedContinuation { continuation in
            // Do not let fast scrolling pile up hundreds of jobs.
            if queue.count >= 40 {
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
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        activeJob = job
        start(job)
    }

    private func start(_ job: Job) {
        let player = VLCMediaPlayer()
        let view = makeSurface()
        player.drawable = view
        player.media = VLCMedia(url: job.url)
        player.play()
        player.audio?.isMuted = true

        self.player = player
        self.surface = view
        self.deadline = Date().addingTimeInterval(12)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let player, let deadline else { return }
        let seconds = Double(player.time.intValue) / 1000.0
        if seconds >= 3.0 || Date() > deadline {
            finish()
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil

        guard let player, let job = activeJob else { return }
        let destination = cacheDirectory.appendingPathComponent(Self.key(for: job.entry) + ".jpg")
        try? FileManager.default.removeItem(at: destination)
        player.saveVideoSnapshot(at: destination.path, withWidth: 640, andHeight: 360)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let image = (try? Data(contentsOf: destination)).flatMap { UIImage(data: $0) }
            player.stop()
            self.surface?.removeFromSuperview()
            self.surface = nil
            self.player = nil
            self.deadline = nil
            self.activeJob = nil
            self.busy = false
            job.completion(image)
            self.pump()
        }
    }

    // MARK: - Helpers

    private func makeSurface() -> UIView {
        // Must sit inside the window (not off-screen) or VLC will not create a
        // video output; alpha 0.02 keeps it invisible to the user.
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
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
