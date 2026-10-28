import SwiftUI
import UniformTypeIdentifiers

/// iPad shell drawn by hand: sidebar + detail. No NavigationSplitView, so no
/// system navigation bar and no extra black bands around the content.
struct RootView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var peers = PeerService()
    @State private var showPicker = false
    @State private var showSpeedTest = false
    @State private var showDevices = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                SidebarView(
                    showPicker: $showPicker,
                    showSpeedTest: $showSpeedTest,
                    showDevices: $showDevices,
                    peers: peers
                )
                    .frame(width: geo.size.width < 780 ? 248 : 300)

                Rectangle()
                    .fill(CF.line)
                    .frame(width: 1)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CF.bg0.ignoresSafeArea())
        .task {
            app.restoreLastIfNeeded()
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    app.open(url: url)
                }
            case .failure(let error):
                app.errorMessage = error.localizedDescription
            }
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { app.errorMessage != nil },
                set: { newValue in if !newValue { app.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
        .sheet(isPresented: $showSpeedTest) {
            SpeedTestView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showDevices) {
            DevicesView()
                .environmentObject(app)
                .environmentObject(peers)
                .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $app.playingRequest) { request in
            PlayerScreen(
                url: request.url,
                title: request.title,
                progressKey: request.progressKey
            )
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if app.currentSource != nil {
            BrowserView()
        } else {
            WelcomeView(showPicker: $showPicker, showSpeedTest: $showSpeedTest)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var app: AppState
    @Binding var showPicker: Bool
    @Binding var showSpeedTest: Bool
    @Binding var showDevices: Bool
    @ObservedObject var peers: PeerService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    librarySection
                    networkSection
                    if app.currentSource != nil {
                        folderSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }

            Spacer(minLength: 0)
            Hairline()
            devicesButton
            speedTestButton
            footer
        }
        .background(CF.bg1)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(CF.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("CINEFILE")
                    .font(CF.ui(16, weight: .bold))
                    .tracking(2.4)
                    .foregroundColor(CF.text1)
                Text("文件夹即片库 · 不转码")
                    .font(CF.ui(11))
                    .foregroundColor(CF.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Libraries · 片库")
            if app.libraries.isEmpty {
                Text("还没有片库。打开一个包含视频的文件夹即可开始。")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(app.libraries) { ref in
                    libraryRow(ref)
                }
            }
            Button {
                showPicker = true
            } label: {
                Label("打开文件夹…", systemImage: "folder.badge.plus")
                    .font(CF.ui(CF.fontBody, weight: .medium))
                    .foregroundColor(CF.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: CF.radiusSmall)
                            .fill(CF.bg2)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func libraryRow(_ ref: LibraryRef) -> some View {
        var active = false
        if case .local(let current) = app.currentSource {
            active = current.id == ref.id
        }
        return Button {
            app.open(ref)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 14))
                    .foregroundColor(active ? CF.accent : CF.text3)
                Text(ref.name)
                    .font(CF.ui(CF.fontBody, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? CF.text1 : CF.text2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: CF.radiusSmall)
                    .fill(active ? CF.bg3 : Color.clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CF.accent)
                        .frame(width: 3, height: 20)
                        .padding(.leading, 2)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                app.forget(ref)
            } label: {
                Label("从片库移除", systemImage: "trash")
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Network · 网络片库")
            if peers.paired.isEmpty {
                Text("配对 PC 后，对方的片库会出现在这里。")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(peers.paired) { peer in
                    networkRow(peer)
                }
            }
        }
    }

    private func networkRow(_ peer: PairedPeer) -> some View {
        let online = peers.isOnline(peer)
        var active = false
        if case .network(let current) = app.currentSource {
            active = current.instanceId == peer.instanceId
        }
        return Button {
            guard let access = peers.access(for: peer) else { return }
            Task { await app.openNetwork(peer: peer, access: access) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 14))
                    .foregroundColor(active || online ? CF.accent : CF.text3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.hostname)
                        .font(CF.ui(14, weight: active ? .semibold : .medium))
                        .foregroundColor(active ? CF.text1 : CF.text1)
                        .lineLimit(1)
                    Text(peer.shareLabel.isEmpty ? "网络共享" : peer.shareLabel)
                        .font(CF.mono(CF.fontCaption))
                        .foregroundColor(CF.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(online ? CF.success : CF.text3)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: CF.radiusSmall)
                    .fill(active ? CF.bg3 : CF.bg2)
            )
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CF.accent)
                        .frame(width: 3, height: 20)
                        .padding(.leading, 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Folders · 文件夹")
            let folders = app.entries.filter { $0.isDirectory }
            if folders.isEmpty {
                Text("当前文件夹没有子文件夹")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text3)
            } else {
                ForEach(folders) { entry in
                    Button {
                        app.activate(entry)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 14))
                                .foregroundColor(CF.text3)
                            Text(entry.name)
                                .font(CF.ui(14))
                                .foregroundColor(CF.text2)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var devicesButton: some View {
        Button {
            showDevices = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .medium))
                Text("附近设备")
                    .font(CF.ui(CF.fontSmall, weight: .medium))
                Spacer(minLength: 0)
                Text("PC 端配对")
                    .font(CF.mono(CF.fontCaption))
                    .foregroundColor(CF.text3)
            }
            .foregroundColor(CF.text2)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var speedTestButton: some View {
        Button {
            showSpeedTest = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(.system(size: 14, weight: .medium))
                Text("连接速度测试")
                    .font(CF.ui(CF.fontSmall, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(CF.text2)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LOCAL · DIRECT PLAY")
            Text("NO SERVER · NO SCRAPING")
        }
        .font(CF.mono(10))
        .foregroundColor(CF.text3)
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject private var app: AppState
    @Binding var showPicker: Bool
    @Binding var showSpeedTest: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CINEFILE")
                        .font(CF.ui(40, weight: .bold))
                        .tracking(4)
                        .foregroundColor(CF.text1)
                    Text("文件夹即片库。不部署服务端，不刮削，不转码。")
                        .font(CF.ui(17))
                        .foregroundColor(CF.text2)
                }

                HStack(spacing: 12) {
                    Button {
                        showPicker = true
                    } label: {
                        Label("打开文件夹", systemImage: "folder.fill.badge.plus")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(CFButtonStyle(primary: true))

                    Button {
                        showSpeedTest = true
                    } label: {
                        Label("连接速度测试", systemImage: "speedometer")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(CFButtonStyle())
                }

                if !app.libraries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "Recent · 最近")
                        ForEach(app.libraries.prefix(4)) { ref in
                            Button {
                                app.open(ref)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive.fill")
                                        .font(.system(size: 15))
                                        .foregroundColor(CF.accent)
                                    Text(ref.name)
                                        .font(CF.ui(CF.fontBody))
                                        .foregroundColor(CF.text1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(CF.text3)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 560)
                }

                smbHint

                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
        .background(CF.bg0)
    }

    /// iPad has no shared video folder of its own in most setups; the system
    /// Files app can mount an SMB server, and that location is selectable here.
    private var smbHint: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(CF.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text("片库在电脑或 NAS 上？")
                    .font(CF.ui(CF.fontBody, weight: .semibold))
                    .foregroundColor(CF.text1)
                Text("应用内直连 SMB 正在开发中。现在可以先用 iPad 的「文件」App 连接服务器：浏览 → 右上角 ⋯ → 连接服务器 → 输入 smb://电脑IP，连上后回到这里选择那个位置。")
                    .font(CF.ui(14))
                    .foregroundColor(CF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("选好后可以先用「连接速度测试」确认带宽够不够。")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CF.radius).fill(CF.bg2))
    }
}
