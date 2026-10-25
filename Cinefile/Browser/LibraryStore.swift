import Foundation

/// A saved library: a local folder the user picked, kept alive with a
/// security-scoped bookmark so access survives app restarts.
struct LibraryRef: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var bookmark: Data
    var lastPath: String
    var lastOpened: Date
}

/// Persists the recent-library list in Application Support.
final class LibraryStore {
    private let fileURL: URL
    private let maxLibraries = 8

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cinefile", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("libraries.json")
    }

    func load() -> [LibraryRef] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([LibraryRef].self, from: data)) ?? []
    }

    private func save(_ refs: [LibraryRef]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(refs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Add or refresh a library and move it to the top of the list.
    @discardableResult
    func add(url: URL) -> LibraryRef? {
        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }

        var refs = load()
        let key = Self.key(for: url)
        let now = Date()

        if let index = refs.firstIndex(where: { $0.id == key }) {
            refs[index].bookmark = bookmark
            refs[index].name = url.lastPathComponent
            refs[index].lastOpened = now
            let ref = refs[index]
            save(refs)
            return ref
        }

        let ref = LibraryRef(
            id: key,
            name: url.lastPathComponent,
            bookmark: bookmark,
            lastPath: url.path,
            lastOpened: now
        )
        refs.insert(ref, at: 0)
        if refs.count > maxLibraries {
            refs = Array(refs.prefix(maxLibraries))
        }
        save(refs)
        return ref
    }

    /// Resolve a bookmark, refreshing it when the system marks it stale.
    func resolve(_ ref: LibraryRef) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: ref.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }

        if stale,
           let fresh = try? url.bookmarkData(
               options: [],
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            var refs = load()
            if let index = refs.firstIndex(where: { $0.id == ref.id }) {
                refs[index].bookmark = fresh
                save(refs)
            }
        }
        return url
    }

    func updateLastPath(id: String, path: String) {
        var refs = load()
        guard let index = refs.firstIndex(where: { $0.id == id }) else { return }
        refs[index].lastPath = path
        refs[index].lastOpened = Date()
        save(refs)
    }

    func touch(_ ref: LibraryRef) -> [LibraryRef] {
        var refs = load()
        if let index = refs.firstIndex(where: { $0.id == ref.id }) {
            refs[index].lastOpened = Date()
        }
        refs.sort { $0.lastOpened > $1.lastOpened }
        save(refs)
        return refs
    }

    func remove(id: String) {
        var refs = load()
        refs.removeAll { $0.id == id }
        save(refs)
    }

    static func key(for url: URL) -> String {
        "local:" + url.standardizedFileURL.path
    }
}
