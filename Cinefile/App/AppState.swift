import Foundation
import SwiftUI

/// Global shell state: one browser that can show a local folder or a paired
/// peer's SMB share. Both go through the same entries / grid / sorting path, so
/// a network library feels exactly like opening a folder.
@MainActor
final class AppState: ObservableObject {
    enum Source: Equatable {
        case local(LibraryRef)
        case network(PairedPeer)
    }

    struct Crumb: Identifiable, Equatable {
        let id: String
        let name: String
        let localURL: URL?
        let remotePath: String?
    }

    @Published var libraries: [LibraryRef] = []
    @Published var currentSource: Source?
    @Published var entries: [Entry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var playingRequest: PlayRequest?
    @Published var sortMode: SortMode = .name
    @Published var remotePath = ""

    private let store = LibraryStore()
    private let peerStore = PeerStore()
    private var scopedURL: URL?
    private var rootURL: URL?
    private var currentLocalURL: URL?
    private var didRestore = false

    private var smbClient: SMBClient?
    private var smbAccess: SMBAccess?

    init() {
        libraries = store.load()
    }

    /// Reopen where the user left off: the paired peer's share when that was
    /// the last library, otherwise the most recent local folder.
    func restoreLastIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        guard currentSource == nil else { return }

        if peerStore.preferNetworkOnLaunch,
           let id = peerStore.lastNetworkPeerId,
           let peer = peerStore.load().first(where: { $0.instanceId == id }),
           let access = peerStore.access(for: peer) {
            Task { await restoreNetwork(peer: peer, access: access) }
            return
        }

        if let first = libraries.first {
            open(first)
        }
    }

    /// Reconnect to the last network library without any user action. A PC that
    /// is powered off simply falls back to the local library — no error dialog.
    private func restoreNetwork(peer: PairedPeer, access: SMBAccess) async {
        guard await SMBClient.isReachable(host: access.server) else {
            if let first = libraries.first { open(first) }
            return
        }

        await openNetwork(peer: peer, access: access)

        guard currentSource != nil else {
            if let first = libraries.first { open(first) }
            return
        }

        let folder = peerStore.lastNetworkFolder
        if !folder.isEmpty {
            navigateRemote(folder)
        }
    }

    // MARK: - Derived

    var isNetwork: Bool {
        if case .network = currentSource { return true }
        return false
    }

    var currentTitle: String {
        switch currentSource {
        case .local:
            return currentLocalURL?.lastPathComponent ?? "Cinefile"
        case .network(let peer):
            if remotePath.isEmpty { return peer.hostname }
            return remotePath.split(separator: "/").last.map(String.init) ?? peer.hostname
        case .none:
            return "Cinefile"
        }
    }

    var filteredEntries: [Entry] {
        let ordered = entries.sortedByMode(sortMode)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var folderCount: Int { entries.filter { $0.isDirectory }.count }
    var videoCount: Int { entries.filter { !$0.isDirectory }.count }

    var breadcrumbs: [Crumb] {
        switch currentSource {
        case .local:
            guard let root = rootURL, let current = currentLocalURL else { return [] }
            let rootStd = root.standardizedFileURL
            let currentStd = current.standardizedFileURL
            var items = [Crumb(id: "root", name: rootStd.lastPathComponent, localURL: rootStd, remotePath: nil)]

            let rootPath = rootStd.path
            let currentPath = currentStd.path
            guard currentPath != rootPath, currentPath.hasPrefix(rootPath + "/") else { return items }

            let relative = String(currentPath.dropFirst(rootPath.count + 1))
            var accumulated = rootStd
            for (index, component) in relative.split(separator: "/").enumerated() where !component.isEmpty {
                accumulated = accumulated.appendingPathComponent(String(component))
                items.append(
                    Crumb(
                        id: "local-\(index)",
                        name: String(component),
                        localURL: accumulated,
                        remotePath: nil
                    )
                )
            }
            return items

        case .network(let peer):
            var items = [Crumb(id: "net-root", name: peer.hostname, localURL: nil, remotePath: "")]
            var accumulated = ""
            for (index, component) in remotePath.split(separator: "/").enumerated() {
                accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
                items.append(
                    Crumb(
                        id: "net-\(index)",
                        name: String(component),
                        localURL: nil,
                        remotePath: accumulated
                    )
                )
            }
            return items

        case .none:
            return []
        }
    }

    var canGoUp: Bool {
        switch currentSource {
        case .local:
            guard let current = currentLocalURL, let root = rootURL else { return false }
            return current.standardizedFileURL.path != root.standardizedFileURL.path
        case .network:
            return !remotePath.isEmpty
        case .none:
            return false
        }
    }

    // MARK: - Local libraries

    func open(_ ref: LibraryRef) {
        guard let url = store.resolve(ref) else {
            errorMessage = "无法访问「\(ref.name)」，请重新选择这个文件夹。"
            return
        }
        closeSMB()
        stopScope()
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        rootURL = url
        currentSource = .local(ref)
        libraries = store.touch(ref)
        peerStore.preferNetworkOnLaunch = false

        let restored = URL(fileURLWithPath: ref.lastPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: restored.path, isDirectory: &isDirectory)
        let insideRoot = restored.path == url.path || restored.path.hasPrefix(url.path + "/")
        if exists && isDirectory.boolValue && insideRoot {
            navigateLocal(restored)
        } else {
            navigateLocal(url)
        }
    }

    func open(url: URL) {
        closeSMB()
        stopScope()
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        rootURL = url

        let ref = store.add(url: url) ?? LibraryRef(
            id: LibraryStore.key(for: url),
            name: url.lastPathComponent,
            bookmark: Data(),
            lastPath: url.path,
            lastOpened: Date()
        )
        currentSource = .local(ref)
        libraries = store.load()
        peerStore.preferNetworkOnLaunch = false
        navigateLocal(url)
    }

    // MARK: - Network library

    func openNetwork(peer: PairedPeer, access: SMBAccess) async {
        stopScope()
        closeSMB()

        guard let client = SMBClient(access: access) else {
            errorMessage = "无法创建 SMB 连接：地址或凭据格式不正确。"
            return
        }

        isLoading = true
        errorMessage = nil
        searchText = ""
        remotePath = ""
        entries = []

        do {
            try await client.connect()
            smbClient = client
            smbAccess = access
            currentSource = .network(peer)
            peerStore.lastNetworkPeerId = peer.instanceId
            peerStore.lastNetworkFolder = ""
            peerStore.preferNetworkOnLaunch = true

            let items = try await client.list("")
            entries = items
                .map(Self.remoteEntry)
                .filter { $0.isDirectory || DirectoryLister.isVideo($0.name) }
            prefetchThumbnails()
        } catch {
            errorMessage = "连接 \(access.server) 失败：\(error.localizedDescription)"
            currentSource = nil
        }
        isLoading = false
    }

    private static func remoteEntry(_ item: SMBEntry) -> Entry {
        Entry(
            id: "remote:\(item.path)",
            name: item.name,
            location: .remote(path: item.path),
            isDirectory: item.isDirectory,
            size: item.size,
            mtime: item.mtime
        )
    }

    // MARK: - Navigation

    func navigateLocal(_ url: URL) {
        isLoading = true
        errorMessage = nil
        searchText = ""

        Task {
            do {
                let list = try await Task.detached(priority: .userInitiated) {
                    try DirectoryLister.list(url)
                }.value
                entries = list
                currentLocalURL = url
                if case .local(var ref) = currentSource {
                    ref.lastPath = url.path
                    currentSource = .local(ref)
                    store.updateLastPath(id: ref.id, path: url.path)
                }
            } catch {
                entries = []
                currentLocalURL = url
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    func navigateRemote(_ path: String) {
        guard let client = smbClient else { return }
        isLoading = true
        errorMessage = nil
        searchText = ""

        Task {
            do {
                let items = try await client.list(path)
                entries = items
                    .map(Self.remoteEntry)
                    .filter { $0.isDirectory || DirectoryLister.isVideo($0.name) }
                remotePath = path
                peerStore.lastNetworkFolder = path
                prefetchThumbnails()
            } catch {
                entries = []
                errorMessage = "读取目录失败：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    /// Pull the rest of the folder's thumbnails in the background, so scrolling
    /// and coming back later is instant. Visible cards always jump the queue.
    private func prefetchThumbnails() {
        guard let access = smbAccess else { return }
        let videos = entries.filter { !$0.isDirectory }
        guard !videos.isEmpty else { return }
        RemoteThumbnailService.shared.prefetch(videos, access: access)
    }

    func reload() {
        if isNetwork {
            navigateRemote(remotePath)
        } else if let current = currentLocalURL {
            navigateLocal(current)
        }
    }

    func goUp() {
        switch currentSource {
        case .local:
            guard let current = currentLocalURL, let root = rootURL else { return }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            let rootStd = root.standardizedFileURL
            guard parent.path != current.standardizedFileURL.path else { return }
            guard parent.path == rootStd.path || parent.path.hasPrefix(rootStd.path + "/") else { return }
            navigateLocal(parent)

        case .network:
            let parent = remotePath.split(separator: "/").dropLast().joined(separator: "/")
            navigateRemote(parent)

        case .none:
            break
        }
    }

    func goRoot() {
        switch currentSource {
        case .local:
            if let root = rootURL { navigateLocal(root) }
        case .network:
            navigateRemote("")
        case .none:
            break
        }
    }

    func openCrumb(_ crumb: Crumb) {
        if let url = crumb.localURL {
            navigateLocal(url)
        } else if let path = crumb.remotePath {
            navigateRemote(path)
        }
    }

    // MARK: - Entries

    func activate(_ entry: Entry) {
        if entry.isDirectory {
            switch entry.location {
            case .local(let url):
                navigateLocal(url)
            case .remote(let path):
                navigateRemote(path)
            }
            return
        }

        switch entry.location {
        case .local(let url):
            playingRequest = PlayRequest(
                url: url,
                title: entry.name,
                progressKey: PlaybackProgressStore.key(for: entry)
            )

        case .remote(let path):
            guard let access = smbAccess, let url = access.playbackURL(relativePath: path) else {
                errorMessage = "无法为这个文件生成播放地址。"
                return
            }
            playingRequest = PlayRequest(
                url: url,
                title: entry.name,
                progressKey: PlaybackProgressStore.key(for: entry)
            )
        }
    }

    // MARK: - Lifecycle

    func closeLibrary() {
        closeSMB()
        stopScope()
        currentSource = nil
        currentLocalURL = nil
        rootURL = nil
        remotePath = ""
        entries = []
        searchText = ""
        errorMessage = nil
        peerStore.preferNetworkOnLaunch = false
    }

    func forget(_ ref: LibraryRef) {
        store.remove(id: ref.id)
        libraries = store.load()
        if case .local(let current) = currentSource, current.id == ref.id {
            closeLibrary()
        }
    }

    private func stopScope() {
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        scopedURL = nil
    }

    private func closeSMB() {
        if let client = smbClient {
            Task { await client.disconnect() }
        }
        smbClient = nil
        smbAccess = nil
    }

    /// SMB credentials for the active network library (used by thumbnails/speed test).
    var activeSMBAccess: SMBAccess? { smbAccess }

    var activeSMBClient: SMBClient? { smbClient }

    /// Local folder currently shown (nil for network libraries).
    var currentLocalFolder: URL? { currentLocalURL }
}
