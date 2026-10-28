import Foundation
import Security

/// Paired peer records in Application Support; SMB credentials in the Keychain.
///
/// The desktop build seals credentials with DPAPI; iOS has no DPAPI, so the
/// equivalent is a generic-password item that never leaves this device
/// (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).
final class PeerStore {
    private let fileURL: URL
    private let service = "app.cinefile.ios.peer"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cinefile", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("peers.json")
    }

    // MARK: - Records

    func load() -> [PairedPeer] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PairedPeer].self, from: data)) ?? []
    }

    private func save(_ peers: [PairedPeer]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(peers) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func upsert(_ peer: PairedPeer) {
        var peers = load()
        if let index = peers.firstIndex(where: { $0.instanceId == peer.instanceId }) {
            peers[index] = peer
        } else {
            peers.insert(peer, at: 0)
        }
        save(peers)
    }

    func remove(instanceId: String) {
        var peers = load()
        peers.removeAll { $0.instanceId == instanceId }
        save(peers)
        keychainDelete(account: instanceId)
    }

    func updateAddress(instanceId: String, address: String) {
        var peers = load()
        guard let index = peers.firstIndex(where: { $0.instanceId == instanceId }) else { return }
        peers[index].lastAddress = address
        save(peers)
    }

    // MARK: - Credentials

    func saveAccess(_ access: SMBAccess, for instanceId: String) {
        guard let data = try? JSONEncoder().encode(access) else { return }
        keychainDelete(account: instanceId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: instanceId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func access(for instanceId: String) -> SMBAccess? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: instanceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let access = try? JSONDecoder().decode(SMBAccess.self, from: data)
        else {
            return nil
        }
        return access
    }

    /// Credentials for a paired peer, re-pointed at the IPv4 address we last
    /// reached it on. The desktop hands over its NetBIOS name (DESKTOP-XXXX),
    /// which iOS cannot resolve through getaddrinfo.
    func access(for peer: PairedPeer) -> SMBAccess? {
        guard var access = access(for: peer.instanceId) else { return nil }
        if Self.isIPv4(peer.lastAddress) {
            access.server = peer.lastAddress
        }
        return access
    }

    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }

    // MARK: - Launch state

    private enum Key {
        static let peer = "cinefile.lastNetworkPeer"
        static let folder = "cinefile.lastNetworkFolder"
        static let preferNetwork = "cinefile.launchIntoNetwork"
    }

    /// Which network library was open last time (nil = never used one).
    var lastNetworkPeerId: String? {
        get { UserDefaults.standard.string(forKey: Key.peer) }
        set { UserDefaults.standard.set(newValue, forKey: Key.peer) }
    }

    /// Folder inside that library, so the app reopens where the user left off.
    var lastNetworkFolder: String {
        get { UserDefaults.standard.string(forKey: Key.folder) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.folder) }
    }

    /// True when the last thing the user browsed was a peer's share.
    var preferNetworkOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Key.preferNetwork) }
        set { UserDefaults.standard.set(newValue, forKey: Key.preferNetwork) }
    }

    private func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
