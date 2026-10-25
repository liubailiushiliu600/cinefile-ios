import Foundation

/// One row in the browser: a folder or a playable video file.
struct Entry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let mtime: Date

    var displaySize: String {
        guard !isDirectory else { return "" }
        return Self.formatSize(size)
    }

    static func formatSize(_ size: Int64) -> String {
        var value = Double(max(0, size))
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if value < 1024 || unit == "TB" {
                if unit == "B" {
                    return String(format: "%.0f %@", value, unit)
                }
                return String(format: "%.1f %@", value, unit)
            }
            value /= 1024
        }
        return String(format: "%.1f TB", value)
    }
}

/// Folder enumeration, matching cinefile/library.py:
/// folders first, then videos, natural name order, hidden/system entries skipped.
enum DirectoryLister {
    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts",
        "webm", "wmv", "flv", "mpg", "mpeg", "ogv", "rmvb"
    ]

    static let skipNames: Set<String> = [
        "$RECYCLE.BIN", "System Volume Information", ".DS_Store"
    ]

    static func isVideo(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func list(_ folder: URL) throws -> [Entry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey
        ]

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DirectoryError.readFailed(folder.lastPathComponent)
        }

        var entries: [Entry] = []
        entries.reserveCapacity(urls.count)

        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || skipNames.contains(name) { continue }

            let values = try? url.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory ?? false
            if !isDirectory && !isVideo(name) { continue }

            entries.append(
                Entry(
                    id: url.standardizedFileURL.path,
                    name: name,
                    url: url,
                    isDirectory: isDirectory,
                    size: Int64(values?.fileSize ?? 0),
                    mtime: values?.contentModificationDate ?? .distantPast
                )
            )
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    /// Immediate child folders of a folder (used by the sidebar tree).
    static func subfolders(_ folder: URL) -> [Entry] {
        (try? list(folder))?.filter { $0.isDirectory } ?? []
    }
}

enum DirectoryError: LocalizedError {
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let name):
            return "无法读取文件夹「\(name)」，请检查权限或重新选择片库。"
        }
    }
}
