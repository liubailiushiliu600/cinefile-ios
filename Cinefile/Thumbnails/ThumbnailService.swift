import AVFoundation
import CryptoKit
import UIKit

/// Generates and caches 16:9 video thumbnails.
///
/// Mirrors cinefile/thumbnail_cache.py: seek to ~20% of the duration
/// (clamped to 3–120 s), scale to 640 px wide, cache by
/// `sha256(path|mtime|size|thumb-v1)` on disk.
final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    private let cacheDirectory: URL
    private var memory: [String: UIImage] = [:]
    private let lock = NSLock()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches
            .appendingPathComponent("Cinefile", isDirectory: true)
            .appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func thumbnail(for entry: Entry) async -> UIImage? {
        guard !entry.isDirectory, let url = entry.localURL else { return nil }
        let key = Self.key(for: entry)

        if let cached = cachedImage(key) { return cached }

        let destination = cacheDirectory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: destination), let image = UIImage(data: data) {
            store(key, image)
            return image
        }

        let image = await Task.detached(priority: .utility) {
            Self.generate(url: url)
        }.value

        guard let image else { return nil }
        store(key, image)
        if let data = image.jpegData(compressionQuality: 0.72) {
            try? data.write(to: destination, options: .atomic)
        }
        return image
    }

    // MARK: - Cache

    private func cachedImage(_ key: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return memory[key]
    }

    private func store(_ key: String, _ image: UIImage) {
        lock.lock()
        // 60 frames at 480x270 ≈ 30 MB; 240 frames was a memory bomb on 3 GB iPads.
        if memory.count > 60 { memory.removeAll(keepingCapacity: true) }
        memory[key] = image
        lock.unlock()
    }

    static func key(for entry: Entry) -> String {
        let material = "\(entry.id)|\(entry.mtime.timeIntervalSince1970)|\(entry.size)|thumb-v1"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Generation

    private static func generate(url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let duration = CMTimeGetSeconds(asset.duration)
        let seek: Double
        if !duration.isFinite || duration <= 0 {
            seek = 3.0
        } else if duration < 8 {
            seek = 0.5
        } else {
            seek = min(max(3.0, duration * 0.2), 120.0)
        }

        let time = CMTime(seconds: seek, preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
}
