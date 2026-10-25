import AMSMB2
import Foundation

/// One entry inside a paired peer's SMB share.
struct SMBEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64

    var id: String { path }
}

/// SMB client for browsing a paired peer's share (AMSMB2 / libsmb2).
/// Playback itself is handed to VLC, which ships its own libsmb2 plugin.
final class SMBClient {
    let access: SMBAccess
    private let manager: SMB2Manager

    init?(access: SMBAccess) {
        guard let url = URL(string: "smb://\(access.server)") else { return nil }
        guard let manager = SMB2Manager(url: url, user: access.username, password: access.password) else {
            return nil
        }
        self.access = access
        self.manager = manager
    }

    func connect() async throws {
        try await manager.connect()
    }

    func disconnect() async {
        await manager.disconnect()
    }

    /// List a path relative to the share root ("" = share root).
    func list(_ relativePath: String) async throws -> [SMBEntry] {
        let full = fullPath(relativePath)
        let items = try await manager.contentsOfDirectory(atPath: full)
        var entries: [SMBEntry] = []
        for item in items {
            let name = item.name
            if name.hasPrefix(".") || name == "$RECYCLE.BIN" || name == "System Volume Information" {
                continue
            }
            entries.append(
                SMBEntry(
                    name: name,
                    path: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                    isDirectory: item.isDirectory,
                    size: Int64(item.size)
                )
            )
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    func fullPath(_ relativePath: String) -> String {
        let share = access.share.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rest = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rest.isEmpty { return "/\(share)" }
        return "/\(share)/\(rest)"
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
