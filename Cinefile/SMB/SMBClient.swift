import AMSMB2
import Foundation
import Network

/// One entry inside a paired peer's SMB share.
struct SMBEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let mtime: Date

    var id: String { path }
}

/// SMB client for browsing a paired peer's share (AMSMB2 / libsmb2).
/// Playback itself is handed to VLC, which ships its own libsmb2 plugin.
final class SMBClient: @unchecked Sendable {
    let access: SMBAccess
    private let manager: SMB2Manager

    init?(access: SMBAccess) {
        guard let url = URL(string: "smb://\(access.server)") else { return nil }
        let credential = URLCredential(
            user: access.username,
            password: access.password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: url, credential: credential) else { return nil }
        self.access = access
        self.manager = manager
    }

    /// Connect and mount the share; paths afterwards are relative to its root.
    func connect() async throws {
        try await manager.connectShare(name: access.share)
    }

    func disconnect() async {
        try? await manager.disconnectShare()
    }

    /// List a path relative to the share root ("" = share root).
    func list(_ relativePath: String) async throws -> [SMBEntry] {
        let path = fullPath(relativePath)
        let items = try await manager.contentsOfDirectory(atPath: path)

        var entries: [SMBEntry] = []
        for item in items {
            guard let name = item[.nameKey] as? String else { continue }
            if name.hasPrefix(".") || name == "$RECYCLE.BIN" || name == "System Volume Information" {
                continue
            }
            let resourceType = item[.fileResourceTypeKey] as? URLFileResourceType
            let isDirectory = resourceType == .directory
            let size = (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            let modified = (item[.contentModificationDateKey] as? Date) ?? .distantPast
            entries.append(
                SMBEntry(
                    name: name,
                    path: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                    isDirectory: isDirectory,
                    size: size,
                    mtime: modified
                )
            )
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    /// Read a whole file (used by the connection speed test on small samples).
    func read(_ relativePath: String) async throws -> Data {
        try await manager.contents(atPath: fullPath(relativePath))
    }

    private func fullPath(_ relativePath: String) -> String {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/\(trimmed)"
    }

    /// Cheap TCP probe (445) so restoring a network library at launch does not
    /// block for a minute when the PC is off or on another Wi-Fi.
    static func isReachable(host: String, port: UInt16 = 445, timeout: TimeInterval = 1.8) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let queue = DispatchQueue(label: "app.cinefile.smb.probe")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let guardFlag = ProbeFlag()

            // Must be @Sendable: Network.framework calls the state handler on
            // its own queue, and Swift 6 would reject a plain nested function.
            let settle: @Sendable (Bool) -> Void = { value in
                guard guardFlag.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    settle(true)
                case .failed, .cancelled:
                    settle(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { settle(false) }
        }
    }
}

/// One-shot flag for the probe above (state handler + timeout race).
private final class ProbeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

extension SMBAccess {
    /// smb://user:password@host/share/path — VLC's libsmb2 plugin opens this
    /// directly, including Range requests when seeking.
    func playbackURL(relativePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = server
        if !username.isEmpty { components.user = username }
        if !password.isEmpty { components.password = password }

        let sharePath = share.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rest = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = rest.isEmpty ? "/\(sharePath)" : "/\(sharePath)/\(rest)"
        return components.url
    }
}
