import Foundation
import SwiftUI

/// Global shell state: current library, current folder, entries, search.
@MainActor
final class AppState: ObservableObject {
    @Published var libraries: [LibraryRef] = []
    @Published var currentLibrary: LibraryRef?
    @Published var rootURL: URL?
    @Published var currentURL: URL?
    @Published var entries: [Entry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var playingEntry: Entry?

    private let store = LibraryStore()
    private var scopedURL: URL?
    private var didRestore = false

    init() {
        libraries = store.load()
    }

    /// Reopen the most recent library once, on first appearance.
    func restoreLastIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        guard currentLibrary == nil, let first = libraries.first else { return }
        open(first)
    }

    // MARK: - Derived

    var filteredEntries: [Entry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var breadcrumbs: [(name: String, url: URL)] {
        guard let root = rootURL, let current = currentURL else { return [] }
        let rootStd = root.standardizedFileURL
        let currentStd = current.standardizedFileURL
        var items: [(name: String, url: URL)] = [(rootStd.lastPathComponent, rootStd)]

        let rootPath = rootStd.path
        let currentPath = currentStd.path
        guard currentPath != rootPath, currentPath.hasPrefix(rootPath + "/") else { return items }

        let relative = String(currentPath.dropFirst(rootPath.count + 1))
        var accumulated = rootStd
        for component in relative.split(separator: "/") where !component.isEmpty {
            accumulated = accumulated.appendingPathComponent(String(component))
            items.append((String(component), accumulated))
        }
        return items
    }

    var canGoUp: Bool {
        guard let current = currentURL, let root = rootURL else { return false }
        return current.standardizedFileURL.path != root.standardizedFileURL.path
    }

    var currentTitle: String {
        currentURL?.lastPathComponent ?? currentLibrary?.name ?? "Cinefile"
    }

    var folderCount: Int { entries.filter { $0.isDirectory }.count }
    var videoCount: Int { entries.filter { !$0.isDirectory }.count }

    // MARK: - Library lifecycle

    func open(_ ref: LibraryRef) {
        guard let url = store.resolve(ref) else {
            errorMessage = "无法访问「\(ref.name)」，请重新选择这个文件夹。"
            return
        }
        stopScope()
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        rootURL = url
        currentLibrary = ref
        libraries = store.touch(ref)

        // Restore the last visited sub-folder when it still exists.
        let restored = URL(fileURLWithPath: ref.lastPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: restored.path, isDirectory: &isDirectory)
        let insideRoot = restored.path == url.path || restored.path.hasPrefix(url.path + "/")
        if exists && isDirectory.boolValue && insideRoot {
            navigate(to: restored)
        } else {
            navigate(to: url)
        }
    }

    func open(url: URL) {
        stopScope()
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url

        let ref = store.add(url: url) ?? LibraryRef(
            id: LibraryStore.key(for: url),
            name: url.lastPathComponent,
            bookmark: Data(),
            lastPath: url.path,
            lastOpened: Date()
        )
        rootURL = url
        currentLibrary = ref
        libraries = store.load()
        navigate(to: url)
    }

    func closeLibrary() {
        stopScope()
        currentLibrary = nil
        rootURL = nil
        currentURL = nil
        entries = []
        searchText = ""
        errorMessage = nil
    }

    func forget(_ ref: LibraryRef) {
        store.remove(id: ref.id)
        libraries = store.load()
        if currentLibrary?.id == ref.id {
            closeLibrary()
        }
    }

    private func stopScope() {
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        scopedURL = nil
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        isLoading = true
        errorMessage = nil
        searchText = ""

        Task {
            do {
                let list = try await Task.detached(priority: .userInitiated) {
                    try DirectoryLister.list(url)
                }.value
                entries = list
                currentURL = url
                if var library = currentLibrary {
                    library.lastPath = url.path
                    currentLibrary = library
                    store.updateLastPath(id: library.id, path: url.path)
                }
            } catch {
                entries = []
                currentURL = url
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    func reload() {
        guard let current = currentURL else { return }
        navigate(to: current)
    }

    func goUp() {
        guard let current = currentURL, let root = rootURL else { return }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        let rootStd = root.standardizedFileURL
        guard parent.path != current.standardizedFileURL.path else { return }
        guard parent.path == rootStd.path || parent.path.hasPrefix(rootStd.path + "/") else { return }
        navigate(to: parent)
    }

    func goRoot() {
        guard let root = rootURL else { return }
        navigate(to: root)
    }

    // MARK: - Open entries

    func play(_ entry: Entry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            playingEntry = entry
        }
    }
}
