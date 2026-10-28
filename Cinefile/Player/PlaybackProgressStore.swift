import Foundation
import SwiftUI

/// Where the user stopped watching one film.
struct PlaybackProgress: Codable {
    var position: Double
    var duration: Double
    /// Seconds since 1970 — JSON stays tiny and needs no date strategy.
    var updatedAt: Double
    var finished: Bool
}

/// What the grid should say about a film.
struct WatchState {
    let label: String
    let color: Color
    /// 0…1, drawn as a thin bar along the bottom of the card.
    let fraction: Double
    /// Where playback should resume (0 = start from the beginning).
    let resumeAt: Double
}

/// Remembers the playback position of every film, keyed by entry id + size so
/// a replaced file never inherits the old position.
///
/// The desktop app has no such store; this is an iPad-side nicety that makes a
/// network library behave like a media app. Writes are debounced (one flush per
/// 8 s) and pruned to the 400 most recent films.
final class PlaybackProgressStore {
    static let shared = PlaybackProgressStore()

    private struct Payload: Codable {
        var v: Int
        var items: [String: PlaybackProgress]
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var items: [String: PlaybackProgress] = [:]
    private var lastFlush = Date.distantPast
    private let maxItems = 400
    private let flushInterval: TimeInterval = 8

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cinefile", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("progress.json")
        load()
    }

    // MARK: - Key

    /// Stable identity for one film. Size is part of the key, so swapping in a
    /// different encode of the same name starts from zero instead of seeking to
    /// a position that no longer exists.
    static func key(for entry: Entry) -> String {
        "\(entry.id)|\(entry.size)"
    }

    // MARK: - Read

    func progress(for key: String) -> PlaybackProgress? {
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return items[key]
    }

    /// Badge text + resume point for a grid card.
    func state(for entry: Entry) -> WatchState? {
        guard !entry.isDirectory else { return nil }
        guard let stored = progress(for: Self.key(for: entry)) else { return nil }
        let duration = stored.duration
        let fraction: Double
        if duration > 0 {
            fraction = min(max(stored.position / duration, 0), 1)
        } else {
            fraction = stored.finished ? 1 : 0
        }

        if stored.finished || fraction >= 0.95 {
            return WatchState(label: "已看", color: CF.stateWatched, fraction: 1, resumeAt: 0)
        }
        if fraction <= 0.01 && stored.position < 10 {
            return nil
        }

        // Do not resume into the last half minute: that is the credits.
        let resumable = duration <= 0 || stored.position < duration - 30
        return WatchState(
            label: "看 \(Int((fraction * 100).rounded()))%",
            color: CF.stateWatching,
            fraction: fraction,
            resumeAt: resumable ? stored.position : 0
        )
    }

    // MARK: - Write

    func record(key: String, position: Double, duration: Double) {
        guard !key.isEmpty, position.isFinite, position >= 0 else { return }

        lock.lock()
        let previous = items[key]
        let finished = duration > 0 && position >= duration - 15
        let tooEarly = position < 5 && !finished

        if tooEarly {
            // Watched a few seconds and bailed: forget rather than remember 0:03.
            if previous != nil {
                items.removeValue(forKey: key)
            }
        } else {
            items[key] = PlaybackProgress(
                position: position,
                duration: max(duration, previous?.duration ?? 0),
                updatedAt: Date().timeIntervalSince1970,
                finished: finished
            )
        }
        pruneLocked()
        let due = Date().timeIntervalSince(lastFlush) >= flushInterval
        lock.unlock()

        if due { flush() }
    }

    func clear(key: String) {
        guard !key.isEmpty else { return }
        lock.lock()
        items.removeValue(forKey: key)
        lock.unlock()
        flush()
    }

    /// Force the in-memory map to disk (player dismiss, app background).
    func flush() {
        lock.lock()
        let snapshot = items
        lastFlush = Date()
        lock.unlock()

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(Payload(v: 1, items: snapshot)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        lock.lock()
        items = payload.items
        lock.unlock()
    }

    private func pruneLocked() {
        guard items.count > maxItems else { return }
        let ordered = items.sorted { $0.value.updatedAt > $1.value.updatedAt }
        items = Dictionary(uniqueKeysWithValues: ordered.prefix(maxItems).map { ($0.key, $0.value) })
    }
}
