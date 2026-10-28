import CryptoKit
import Darwin
import Foundation
import MobileVLCKit
import UIKit

/// Below this much free memory we stop starting new captures. A VLC instance
/// costs 100–300 MB (it keeps demux caches), which OOMs a 3 GB iPad quickly.
private let minimumFreeMemory: UInt64 = 260 * 1024 * 1024

/// Thumbnails for files on a paired peer's SMB share.
///
/// AVFoundation cannot open `smb://`, so this service briefly plays the file
/// through VLC on a nearly invisible surface and saves one frame
/// (`saveVideoSnapshot`). It seeks straight to the capture point
/// (`:start-time=3`) and disables audio, which is the closest VLC gets to
/// Infuse-style single-frame decoding. Results are cached on disk.
///
/// Two queues keep the grid responsive without hammering the network:
///   * `priorityQueue` — cards that are on screen right now (a caller is
///     awaiting the image);
///   * `backgroundQueue` — the rest of the folder, prefetched after the listing
///     arrives so scrolling and coming back later are instant.
/// One capture runs at a time; a VLC instance per file is ~100 MB and this app
/// targets 3 GB iPads.
@MainActor
final class RemoteThumbnailService {
    static let shared = RemoteThumbnailService()

    private struct Job {
        let entry: Entry
        let url: URL
        /// nil for prefetch jobs: nobody is waiting, failures are silent.
        let completion: ((UIImage?) -> Void)?
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

    private var priorityQueue: [Job] = []
    private var backgroundQueue: [Job] = []
    private var sessions: [UUID: Session] = [:]
    private let maxConcurrent = 1
    /// A folder of 200 films should not queue 200 VLC runs; 48 covers what a
    /// user actually scrolls through and refills on the next visit.
    private let maxPrefetch = 48
    private let cacheDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("Cinefile/RemoteThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public

    func thumbnail(for entry: Entry, access: SMBAccess) async -> UIImage? {
        guard let path = entry.remotePath, let url = access.playbackURL(relativePath: path) else {
            return nil
        }

        if let cached = Self.diskImage(for: entry, in: cacheDirectory) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            // Do not let fast scrolling pile up hundreds of jobs.
            if priorityQueue.count >= 60 {
                continuation.resume(returning: nil)
                return
            }
            priorityQueue.append(
                Job(entry: entry, url: url, completion: { image in
                    continuation.resume(returning: image)
                })
            )
            pump()
        }
    }

    /// Queue the rest of a freshly listed folder. Called once per directory
    /// navigation; a new listing replaces whatever was queued before.
    func prefetch(_ entries: [Entry], access: SMBAccess) {
        backgroundQueue.removeAll()
        guard !PlaybackActivity.shared.isPlaying else { return }

        // Skip whatever the on-screen cards are already capturing.
        var busy = Set(sessions.values.map { Self.key(for: $0.job.entry) })
        for job in priorityQueue { busy.insert(Self.key(for: job.entry)) }

        var queued = 0
        for entry in entries {
            guard queued < maxPrefetch else { break }
            guard !entry.isDirectory,
                  let path = entry.remotePath,
                  let url = access.playbackURL(relativePath: path)
            else { continue }

            let cacheKey = Self.key(for: entry)
            if busy.contains(cacheKey) { continue }

            let destination = cacheDirectory.appendingPathComponent(cacheKey + ".jpg")
            if FileManager.default.fileExists(atPath: destination.path) { continue }

            backgroundQueue.append(Job(entry: entry, url: url, completion: nil))
            queued += 1
        }

        pump()
    }

    // MARK: - Queue

    private func pump() {
        guard !PlaybackActivity.shared.isPlaying else { return }

        // Memory guard: do not start another VLC instance when the device is
        // already tight. Retry later instead of piling up and getting killed.
        let free = os_proc_available_memory()
        if free > 0, free < minimumFreeMemory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.pump()
            }
            return
        }

        while sessions.count < maxConcurrent {
            if !priorityQueue.isEmpty {
                start(priorityQueue.removeFirst())
            } else if !backgroundQueue.isEmpty {
                start(backgroundQueue.removeFirst())
            } else {
                break
            }
        }
    }

    /// Stop every in-flight capture and put the jobs back at the head of their
    /// queue. On-screen cards keep their waiters, so they are retried first.
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

        let waiting = jobs.filter { $0.completion != nil }
        let background = jobs.filter { $0.completion == nil }
        priorityQueue.insert(contentsOf: waiting, at: 0)
        backgroundQueue.insert(contentsOf: background, at: 0)
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
        // Keep the decoder's buffers small: defaults can reserve hundreds of MB.
        media.addOption(":demuxer-max-bytes=8MiB")
        media.addOption(":demuxer-max-back-bytes=2MiB")
        media.addOption(":file-caching=300")
        media.addOption(":network-caching=1000")
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

        let destination = cacheDirectory.appendingPathComponent(Self.key(for: session.job.entry) + ".jpg")
        try? FileManager.default.removeItem(at: destination)
        session.player.saveVideoSnapshot(at: destination.path, withWidth: 480, andHeight: 270)

        // VLC writes the JPEG asynchronously. The previous version waited a
        // fixed 0.5 s for it; polling at 70 ms lands the same frame most of the
        // time and cuts the per-thumbnail cost to about a third.
        deliver(session, attempt: 0)
    }

    private func deliver(_ session: Session, attempt: Int) {
        let destination = cacheDirectory.appendingPathComponent(Self.key(for: session.job.entry) + ".jpg")
        let data = (try? Data(contentsOf: destination)) ?? Data()

        if data.count > 512 || attempt >= 8 {
            let image = data.isEmpty ? nil : UIImage(data: data)
            session.player.stop()
            session.surface.removeFromSuperview()
            sessions.removeValue(forKey: session.id)
            session.job.completion?(image)
            pump()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            self?.deliver(session, attempt: attempt + 1)
        }
    }

    // MARK: - Cache

    private static func diskImage(for entry: Entry, in directory: URL) -> UIImage? {
        let destination = directory.appendingPathComponent(key(for: entry) + ".jpg")
        guard let data = try? Data(contentsOf: destination) else { return nil }
        return UIImage(data: data)
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

    /// mtime is part of the key: a re-encoded file keeps its name and often its
    /// size rounded to the gigabyte, but never its timestamp.
    static func key(for entry: Entry) -> String {
        let material = "\(entry.id)|\(entry.size)|\(entry.mtime.timeIntervalSince1970)|remote-thumb-v2"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
