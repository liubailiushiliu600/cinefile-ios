import Foundation

/// SMB credential handed over by a paired host (same fields as cinefile peer.py).
struct SMBAccess: Codable, Equatable, Sendable {
    var server: String
    var share: String
    var username: String
    var password: String

    var unc: String {
        let host = server.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        let folder = share.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        return "\\\\\(host)\\\(folder)"
    }

    static func from(_ dict: [String: Any]) -> SMBAccess? {
        guard
            let server = (dict["server"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !server.isEmpty,
            let share = (dict["share"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !share.isEmpty
        else { return nil }
        return SMBAccess(
            server: server,
            share: share,
            username: (dict["username"] as? String) ?? "",
            password: (dict["password"] as? String) ?? ""
        )
    }
}

/// Host metadata, only ever delivered inside the encrypted unicast reply.
struct PeerBeacon: Identifiable, Hashable, Sendable {
    let instanceId: String
    let hostname: String
    let pairingPort: UInt16
    let fingerprint: String
    let shareLabel: String
    let address: String
    let transferPort: UInt16
    let noCode: Bool
    let pairingOpen: Bool

    var id: String { instanceId }

    var displayName: String {
        shareLabel.isEmpty ? hostname : "\(hostname) / \(shareLabel)"
    }
}

/// A peer we completed pairing with. Credentials live in the Keychain.
struct PairedPeer: Codable, Identifiable, Equatable, Sendable {
    var instanceId: String
    var hostname: String
    var shareLabel: String
    var fingerprint: String
    var token: String
    var pairedAt: Date
    var lastAddress: String
    var transferPort: UInt16

    var id: String { instanceId }

    var displayName: String {
        shareLabel.isEmpty ? hostname : "\(hostname) / \(shareLabel)"
    }
}

enum PeerError: LocalizedError {
    case socketFailed
    case badPacket
    case badMessage
    case connectionClosed
    case fingerprintMismatch
    case codeRequired
    case invalidCode(Int?)
    case rejected
    case notPaired
    case missingAccess

    var errorDescription: String? {
        switch self {
        case .socketFailed:
            return "无法创建本地网络连接。请确认已允许 Cinefile 访问本地网络。"
        case .badPacket:
            return "收到无法解析的发现数据。"
        case .badMessage:
            return "对方返回了无法识别的配对消息。"
        case .connectionClosed:
            return "连接被对方关闭。"
        case .fingerprintMismatch:
            return "证书指纹不匹配，已中止。请确认你在正确的局域网与设备上。"
        case .codeRequired:
            return "对方没有开启免码配对，请改用 6 位配对码。"
        case .invalidCode(let left):
            if let left, left > 0 {
                return "配对码不正确（还可试 \(left) 次）。"
            }
            return "配对码不正确，或对方的配对窗口已锁定。"
        case .rejected:
            return "对方拒绝了本次配对（可能没点「允许」）。"
        case .notPaired:
            return "这台设备还没有完成配对。"
        case .missingAccess:
            return "配对记录里缺少 SMB 凭据，请重新配对一次。"
        }
    }
}
