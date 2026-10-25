import CryptoKit
import Foundation
import Network
import Security

struct PairingOutcome {
    let instanceId: String
    let hostname: String
    let shareLabel: String
    let fingerprint: String
    let token: String
    let access: SMBAccess
}

/// Pairing guest, wire-compatible with cinefile peer.py v2.2.
///
/// TLS 1.3 to the host's pairing port, pin the SHA-256 of its self-signed
/// certificate (taken from the encrypted discovery reply), then exchange
/// newline-delimited JSON:
///   <- {"type":"hello","instance_id":...,"hostname":...,"share_label":...,"challenge":...}
///   -> {"type":"pair","v":2,"code":"123456","client_name":...,"client_instance":...}
///   <- {"type":"paired","token":...,"access":{"server","share","username","password"}}
///
/// This client does not offer its own share (iOS cannot host SMB), so the
/// desktop sees a v2.1-style one-way pair and reports reverse=false.
enum PairingClient {
    static func pair(
        host: String,
        port: UInt16,
        fingerprint: String,
        code: String,
        useNoCode: Bool,
        timeout: TimeInterval = 12
    ) async throws -> PairingOutcome {
        let connection = try LineConnection(
            host: host,
            port: port,
            expectedFingerprint: fingerprint
        )
        defer { connection.cancel() }

        try await connection.start(timeout: timeout)

        let hello = try await connection.receiveLine()
        guard hello["type"] as? String == "hello" else {
            throw PeerError.badMessage
        }

        var request: [String: Any] = [
            "type": "pair",
            "v": 2,
            "code": useNoCode ? "" : normalize(code),
            "client_name": PeerIdentity.hostname,
            "client_instance": PeerIdentity.instanceId,
            "client_nonce": randomHex(16)
        ]
        if useNoCode {
            request["no_code"] = true
        }

        try await connection.send(request)
        let response = try await connection.receiveLine()

        if response["type"] as? String != "paired" {
            switch response["error"] as? String ?? "unknown" {
            case "code_required":
                throw PeerError.codeRequired
            case "invalid_code":
                throw PeerError.invalidCode(response["attempts_left"] as? Int)
            case "rejected":
                throw PeerError.rejected
            default:
                throw PeerError.badMessage
            }
        }

        guard
            let instanceId = hello["instance_id"] as? String,
            let hostname = hello["hostname"] as? String,
            let accessObject = response["access"] as? [String: Any],
            let access = SMBAccess.from(accessObject)
        else {
            throw PeerError.badMessage
        }

        return PairingOutcome(
            instanceId: instanceId,
            hostname: hostname,
            shareLabel: (hello["share_label"] as? String) ?? "",
            fingerprint: fingerprint.lowercased(),
            token: (response["token"] as? String) ?? "",
            access: access
        )
    }

    /// Keep only decimal digits, mirroring normalize_pairing_code().
    private static func normalize(_ code: String) -> String {
        code.compactMap { $0.wholeNumberValue }.map(String.init).joined()
    }

    private static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Line connection

private final class LineConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cinefile.pairing")
    private var buffer = Data()

    init(host: String, port: UInt16, expectedFingerprint: String) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PeerError.badMessage
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)

        let expected = expectedFingerprint.lowercased()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = SecTrustGetCertificateAtIndex(secTrust, 0) else {
                complete(false)
                return
            }
            let der = SecCertificateCopyData(certificate) as Data
            let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            complete(hash == expected)
        }, queue)

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
    }

    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var finished = false

            func finish(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(PeerError.connectionClosed))
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(PeerError.connectionClosed))
            }
        }
    }

    func send(_ object: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receiveLine() async throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    return object
                }
                throw PeerError.badMessage
            }

            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                throw PeerError.connectionClosed
            }
            buffer.append(chunk)
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
    }
}
