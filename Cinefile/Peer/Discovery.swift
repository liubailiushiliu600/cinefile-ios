import CryptoKit
import Darwin
import Foundation

/// Encrypted LAN discovery, wire-compatible with cinefile peer.py (protocol v2).
///
/// Query (plaintext, minimal): magic/type/v/query_id/epk/salt/pid
/// Reply (unicast, encrypted): magic/type/v/query_id/epk/nonce/ciphertext
///   key  = X25519 shared secret -> HKDF-SHA256(salt, info="Cinefile/peer-discovery/v2/")
///   AEAD = AES-256-GCM, AAD = "Cinefile/peer-response/v2:" + query_id
///
/// The desktop build joins the multicast group 239.255.42.99; iOS has no
/// multicast entitlement without special provisioning, but the responder binds
/// 0.0.0.0:45990, so a LAN broadcast reaches it just the same and the reply
/// comes back unicast to our ephemeral port.
enum Discovery {
    static let port: UInt16 = 45990
    static let magic = "CFPEER2"
    static let version = 2
    static let hkdfInfo = Data("Cinefile/peer-discovery/v2/".utf8)
    static let aadPrefix = "Cinefile/peer-response/v2:"

    static func scan(timeout: TimeInterval = 2.5, attempts: Int = 2) async -> [PeerBeacon] {
        await Task.detached(priority: .userInitiated) {
            runQuery(destination: nil, timeout: timeout, attempts: attempts)
        }.value
    }

    /// Unicast query to one host (manual add). Works even when the Wi-Fi blocks
    /// broadcast or multicast: the desktop responder binds 0.0.0.0:45990 and
    /// answers unicast packets as well, so this is the reliable fallback.
    static func probe(host: String, timeout: TimeInterval = 2.2, attempts: Int = 2) async -> PeerBeacon? {
        await Task.detached(priority: .userInitiated) {
            runQuery(destination: host, timeout: timeout, attempts: attempts).first
        }.value
    }

    // MARK: - Query

    private static func runQuery(destination: String?, timeout: TimeInterval, attempts: Int) -> [PeerBeacon] {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let queryId = randomHex(16)
        let salt = randomBytes(16)

        let query: [String: Any] = [
            "magic": magic,
            "type": "discover",
            "v": version,
            "query_id": queryId,
            "epk": publicKey.base64EncodedString(),
            "salt": salt.base64EncodedString(),
            "pid": PeerIdentity.pid
        ]
        guard let packet = try? JSONSerialization.data(withJSONObject: query, options: []) else {
            return []
        }

        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }

        // 255.255.255.255 is a limited broadcast and is often dropped by APs or
        // host firewalls; directed subnet broadcasts (192.168.x.255) are far
        // more reliable, so query both.
        var targets: [in_addr] = []
        if let destination, !destination.isEmpty {
            var address = in_addr()
            inet_pton(AF_INET, destination, &address)
            targets = [address]
        } else {
            targets = broadcastTargets()
        }
        guard !targets.isEmpty else { return [] }

        var base = sockaddr_in()
        base.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        base.sin_family = sa_family_t(AF_INET)
        base.sin_port = port.bigEndian
        base.sin_addr = targets[0]

        var found: [String: PeerBeacon] = [:]
        var buffer = [UInt8](repeating: 0, count: 16384)
        let deadline = Date().addingTimeInterval(max(0.5, timeout))
        var nextSend = Date()
        var sent = 0

        while Date() < deadline {
            if sent < attempts, Date() >= nextSend {
                for address in targets {
                    var destinationAddress = base
                    destinationAddress.sin_addr = address
                    _ = withUnsafePointer(to: &destinationAddress) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                            packet.withUnsafeBytes { raw in
                                sendto(
                                    descriptor,
                                    raw.baseAddress,
                                    packet.count,
                                    0,
                                    sockaddrPointer,
                                    socklen_t(MemoryLayout<sockaddr_in>.size)
                                )
                            }
                        }
                    }
                }
                sent += 1
                nextSend = Date().addingTimeInterval(0.45)
            }

            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(descriptor, &buffer, buffer.count, 0, address, &fromLength)
                }
            }
            guard received > 0 else { continue }

            let data = Data(buffer[0..<received])
            let address = ipString(from)
            if let beacon = try? decode(data, privateKey: privateKey, queryId: queryId, salt: salt, address: address) {
                found[beacon.instanceId] = beacon
            }
        }

        return Array(found.values)
    }

    // MARK: - Reply

    private static func decode(
        _ data: Data,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        queryId: String,
        salt: Data,
        address: String
    ) throws -> PeerBeacon {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["magic"] as? String == magic,
            object["type"] as? String == "peer",
            (object["v"] as? Int) == version,
            let responseId = (object["query_id"] as? String)?.lowercased(),
            responseId == queryId.lowercased(),
            let epkString = object["epk"] as? String,
            let nonceString = object["nonce"] as? String,
            let cipherString = object["ciphertext"] as? String,
            let epkData = Data(base64Encoded: epkString), epkData.count == 32,
            let nonceData = Data(base64Encoded: nonceString), nonceData.count == 12,
            let cipherData = Data(base64Encoded: cipherString), cipherData.count > 16
        else {
            throw PeerError.badPacket
        }

        let hostKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epkData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: hostKey)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )

        let ciphertext = cipherData.prefix(cipherData.count - 16)
        let tag = cipherData.suffix(16)
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        let aad = Data((aadPrefix + queryId).utf8)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)

        guard let payload = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw PeerError.badPacket
        }

        guard
            let instanceId = payload["instance"] as? String,
            let hostname = payload["host"] as? String,
            let fingerprint = (payload["fingerprint"] as? String)?.lowercased(),
            fingerprint.count == 64,
            let pairingPort = payload["pairing_port"] as? Int,
            pairingPort > 0, pairingPort <= 65535
        else {
            throw PeerError.badPacket
        }

        let transferPort = (payload["transfer_port"] as? Int) ?? 45992

        return PeerBeacon(
            instanceId: instanceId,
            hostname: hostname,
            pairingPort: UInt16(pairingPort),
            fingerprint: fingerprint,
            shareLabel: (payload["share"] as? String) ?? "",
            address: address,
            transferPort: UInt16(clamping: transferPort),
            noCode: (payload["no_code"] as? Bool) ?? false,
            pairingOpen: (payload["pairing_open"] as? Bool) ?? true
        )
    }

    // MARK: - Helpers

    /// Limited broadcast plus every active IPv4 interface's directed broadcast
    /// (e.g. 192.168.1.255), de-duplicated.
    private static func broadcastTargets() -> [in_addr] {
        var results: [in_addr] = []
        var seen = Set<String>()

        func append(_ address: in_addr, _ label: String) {
            guard !label.isEmpty, label != "0.0.0.0", !seen.contains(label) else { return }
            seen.insert(label)
            results.append(address)
        }

        var limited = in_addr()
        inet_pton(AF_INET, "255.255.255.255", &limited)
        append(limited, "255.255.255.255")

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return results }
        defer { freeifaddrs(interfaces) }

        var cursor = interfaces
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            guard let addressPointer = interface.ifa_addr else { continue }
            guard addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(bitPattern: interface.ifa_flags)
            guard
                (flags & IFF_UP) != 0,
                (flags & IFF_LOOPBACK) == 0,
                (flags & IFF_BROADCAST) != 0,
                let destinationPointer = interface.ifa_dstaddr
            else {
                continue
            }

            var address = destinationPointer
                .withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
            append(address, String(cString: buffer))
        }

        return results
    }

    private static func ipString(_ address: sockaddr_in) -> String {
        var raw = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func randomHex(_ count: Int) -> String {
        randomBytes(count).map { String(format: "%02x", $0) }.joined()
    }
}
