import SwiftUI

/// Nearby devices: scan, pair, open the peer's library.
struct DevicesView: View {
    @EnvironmentObject private var peers: PeerService
    @Environment(\.dismiss) private var dismiss

    @State private var pairingTarget: PeerBeacon?
    @State private var openPeer: PairedPeer?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusRow
            discoveredSection
            pairedSection
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 600, alignment: .topLeading)
        .background(CF.bg0)
        .task {
            if peers.discovered.isEmpty {
                await peers.scan()
            }
        }
        .sheet(item: $pairingTarget) { beacon in
            PairingSheet(beacon: beacon)
                .environmentObject(peers)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $openPeer) { peer in
            if let access = peers.access(for: peer) {
                SMBBrowserView(peer: peer, access: access)
                    .preferredColorScheme(.dark)
            } else {
                Text("缺少这台设备的 SMB 凭据，请重新配对。")
                    .padding(40)
                    .background(CF.bg0)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("附近设备")
                    .font(CF.ui(26, weight: .semibold))
                    .foregroundColor(CF.text1)
                Text("与 PC 上的 Cinefile 配对后，可直接浏览并播放对方的片库。")
                    .font(CF.ui(CF.fontBody))
                    .foregroundColor(CF.text3)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(CF.text3)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(CF.bg2))
            }
            .buttonStyle(.plain)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await peers.scan() }
            } label: {
                Label(peers.isScanning ? "扫描中…" : "扫描局域网", systemImage: "antenna.radiowaves.left.and.right")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(CFButtonStyle(primary: true))
            .disabled(peers.isScanning)

            Text(peers.statusText)
                .font(CF.ui(CF.fontSmall))
                .foregroundColor(peers.lastError == nil ? CF.text3 : CF.danger)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Discovered · 已发现")
            if peers.discovered.isEmpty {
                Text(peers.isScanning ? "正在查找…" : "还没有发现设备。")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text3)
                    .padding(.vertical, 6)
            } else {
                ForEach(peers.discovered) { beacon in
                    discoveredRow(beacon)
                }
            }
        }
    }

    private func discoveredRow(_ beacon: PeerBeacon) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16))
                .foregroundColor(CF.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(beacon.displayName)
                    .font(CF.ui(CF.fontBody, weight: .medium))
                    .foregroundColor(CF.text1)
                Text("\(beacon.address) · 配对端口 \(beacon.pairingPort)")
                    .font(CF.mono(CF.fontCaption))
                    .foregroundColor(CF.text3)
            }

            Spacer(minLength: 8)

            if peers.paired.contains(where: { $0.instanceId == beacon.instanceId }) {
                Text("已配对")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.success)
            } else {
                Button("配对") {
                    pairingTarget = beacon
                }
                .buttonStyle(CFButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg2))
    }

    private var pairedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Paired · 已配对")
            if peers.paired.isEmpty {
                Text("还没有配对的设备。")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text3)
                    .padding(.vertical, 6)
            } else {
                ForEach(peers.paired) { peer in
                    pairedRow(peer)
                }
            }
        }
    }

    private func pairedRow(_ peer: PairedPeer) -> some View {
        let online = peers.isOnline(peer)
        return HStack(spacing: 12) {
            Circle()
                .fill(online ? CF.success : CF.text3)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(CF.ui(CF.fontBody, weight: .medium))
                    .foregroundColor(CF.text1)
                Text(online ? "在线 · \(peer.lastAddress)" : "离线 · 上次 \(peer.lastAddress)")
                    .font(CF.mono(CF.fontCaption))
                    .foregroundColor(CF.text3)
            }

            Spacer(minLength: 8)

            Button("打开片库") {
                openPeer = peer
            }
            .buttonStyle(CFButtonStyle(primary: true))

            Menu {
                Button(role: .destructive) {
                    peers.forget(peer)
                } label: {
                    Label("移除配对", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(CF.text3)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg2))
    }
}

// MARK: - Pairing sheet

struct PairingSheet: View {
    let beacon: PeerBeacon
    @EnvironmentObject private var peers: PeerService
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("与 \(beacon.hostname) 配对")
                    .font(CF.ui(22, weight: .semibold))
                    .foregroundColor(CF.text1)
                Text("在 PC 端 Cinefile 的「附近设备」面板里打开码窗，然后点「允许」。")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text3)
            }

            HStack(spacing: 10) {
                TextField("6 位配对码（可留空）", text: $code)
                    .textFieldStyle(.plain)
                    .font(CF.mono(18))
                    .foregroundColor(CF.text1)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg2))
                    .keyboardType(.numberPad)
            }

            if let error = peers.lastError {
                Text(error)
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await run(useNoCode: false) }
                } label: {
                    Text(busy ? "配对中…" : "用配对码配对")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(CFButtonStyle(primary: true))
                .disabled(busy)

                Button {
                    Task { await run(useNoCode: true) }
                } label: {
                    Text("免码请求")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(CFButtonStyle())
                .disabled(busy)

                Spacer(minLength: 0)

                Button("取消") { dismiss() }
                    .buttonStyle(CFButtonStyle())
                    .disabled(busy)
            }

            Text("免码请求需要对方在码窗里点一次「允许」；旧版 PC 端不支持免码，请改用 6 位码。")
                .font(CF.ui(CF.fontCaption))
                .foregroundColor(CF.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 320, alignment: .topLeading)
        .background(CF.bg0)
    }

    private func run(useNoCode: Bool) async {
        busy = true
        let peer = await peers.pair(beacon, code: code, useNoCode: useNoCode)
        busy = false
        if peer != nil {
            dismiss()
        }
    }
}
