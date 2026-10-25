import CryptoKit
import Foundation
import UIKit

/// Stable identity for this install, mirroring cinefile's instance_id + pid.
enum PeerIdentity {
    private static let storageKey = "cinefile.instance.id"

    static var instanceId: String {
        if let value = UserDefaults.standard.string(forKey: storageKey), !value.isEmpty {
            return value
        }
        let suffix = String(UUID().uuidString.lowercased().prefix(12))
        let value = "cinefile-ios-" + suffix
        UserDefaults.standard.set(String(value), forKey: storageKey)
        return String(value)
    }

    static var hostname: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPad" : String(name.prefix(64))
    }

    /// SHA-256 of the instance id: lets paired hosts recognise our queries
    /// without putting a reusable identity on the wire in plaintext.
    static var pid: String {
        SHA256.hash(data: Data(instanceId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
