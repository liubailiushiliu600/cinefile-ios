import Foundation

/// One row in the browser. A folder or a video, either on this device or on a
/// paired peer's SMB share. The browser, grid, sorting and player all work on
/// this single type, so a network library behaves exactly like a local folder.
struct Entry: Identifiable, Hashable, Sendable {
    enum Location: Hashable, Sendable {
        case local(URL)
        case remote(path: String)
    }

    let id: String
    let name: String
    let location: Location
    let isDirectory: Bool
    let size: Int64
    let mtime: Date

    var isRemote: Bool {
        if case .remote = location { return true }
        return false
    }

    var localURL: URL? {
        if case .local(let url) = location { return url }
        return nil
    }

    var remotePath: String? {
        if case .remote(let path) = location { return path }
        return nil
    }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

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

/// Sort order, matching the desktop toolbar (name / date / size, folders first).
enum SortMode: String, CaseIterable, Identifiable {
    case name
    case date
    case size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "按文件名"
        case .date: return "最近修改"
        case .size: return "文件大小"
        }
    }
}

extension Array where Element == Entry {
    func sortedByMode(_ mode: SortMode) -> [Entry] {
        sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch mode {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date:
                if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
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
                    id: "local:\(url.standardizedFileURL.path)",
                    name: name,
                    location: .local(url),
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
