import Foundation
import SwiftUI

/// Owns discovery, pairing and the paired-peer list.
@MainActor
final class PeerService: ObservableObject {
    @Published var discovered: [PeerBeacon] = []
    @Published var paired: [PairedPeer] = []
    @Published var isScanning = false
    @Published var isPairing = false
    @Published var statusText = "点「扫描」查找同一局域网内的 Cinefile 设备。"
    @Published var lastError: String?

    private let store = PeerStore()

    init() {
        paired = store.load()
    }

    // MARK: - Discovery

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        statusText = "正在扫描局域网…"

        let found = await Discovery.scan()

        discovered = found.sorted { $0.hostname < $1.hostname }
        for beacon in found {
            store.updateAddress(instanceId: beacon.instanceId, address: beacon.address)
        }
        paired = store.load()
        isScanning = false

        if found.isEmpty {
            statusText = "没有发现设备。请确认 PC 端 Cinefile 已打开「附近设备」面板并处于同一 Wi-Fi。"
        } else {
            statusText = "发现 \(found.count) 台设备。"
        }
    }

    // MARK: - Pairing

    func pair(_ beacon: PeerBeacon, code: String, useNoCode: Bool) async -> PairedPeer? {
        guard !isPairing else { return nil }
        isPairing = true
        lastError = nil
        statusText = "正在与 \(beacon.hostname) 配对…"

        defer { isPairing = false }

        do {
            let outcome = try await PairingClient.pair(
                host: beacon.address,
                port: beacon.pairingPort,
                fingerprint: beacon.fingerprint,
                code: code,
                useNoCode: useNoCode
            )

            let peer = PairedPeer(
                instanceId: outcome.instanceId,
                hostname: outcome.hostname,
                shareLabel: outcome.shareLabel,
                fingerprint: outcome.fingerprint,
                token: outcome.token,
                pairedAt: Date(),
                lastAddress: beacon.address,
                transferPort: beacon.transferPort
            )
            store.upsert(peer)
            store.saveAccess(outcome.access, for: outcome.instanceId)
            paired = store.load()
            if !discovered.contains(where: { $0.instanceId == outcome.instanceId }) {
                discovered.append(beacon)
            }
            statusText = "已与 \(outcome.hostname) 配对，共享：\(outcome.access.unc)"
            return peer
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            statusText = message
            return nil
        }
    }

    // MARK: - Records

    func forget(_ peer: PairedPeer) {
        store.remove(instanceId: peer.instanceId)
        paired = store.load()
        statusText = "已移除 \(peer.hostname)"
    }

    func access(for peer: PairedPeer) -> SMBAccess? {
        guard var access = store.access(for: peer.instanceId) else { return nil }
        // The desktop hands over its NetBIOS name (e.g. DESKTOP-9A8R1OB), which
        // iOS cannot resolve — getaddrinfo returns "Can not resolve into
        // IPv4/v6". Connect by the IPv4 address we actually reached it on.
        if Self.isIPv4(peer.lastAddress) {
            access.server = peer.lastAddress
        }
        return access
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }

    func isOnline(_ peer: PairedPeer) -> Bool {
        discovered.contains { $0.instanceId == peer.instanceId }
    }

    func beacon(for peer: PairedPeer) -> PeerBeacon? {
        discovered.first { $0.instanceId == peer.instanceId }
    }
}
