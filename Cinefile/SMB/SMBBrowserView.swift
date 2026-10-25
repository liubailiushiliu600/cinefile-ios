import SwiftUI

struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

/// Browse a paired peer's SMB share and play its videos through VLC's
/// built-in libsmb2 plugin (smb:// URL, no local copy).
struct SMBBrowserView: View {
    let peer: PairedPeer
    let access: SMBAccess

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SMBBrowserModel()
    @State private var playRequest: PlayRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
        }
        .background(CF.bg0)
        .task {
            await model.open(access: access)
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerScreen(url: request.url, title: request.title, subtitle: peer.hostname)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(CF.text3)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(CF.bg2))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(CF.ui(19, weight: .semibold))
                    .foregroundColor(CF.text1)
                Text(pathLabel)
                    .font(CF.mono(CF.fontCaption))
                    .foregroundColor(CF.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if !model.path.isEmpty {
                Button {
                    model.goUp()
                } label: {
                    Label("上一级", systemImage: "arrow.up")
                        .font(CF.ui(CF.fontSmall, weight: .medium))
                }
                .buttonStyle(CFButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var pathLabel: String {
        let base = "\(access.server) / \(access.share)"
        return model.path.isEmpty ? base : "\(base) / \(model.path)"
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "连接失败",
                message: error
            )
        } else if model.isLoading && model.entries.isEmpty {
            ProgressView()
                .tint(CF.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            EmptyStateView(
                systemImage: "folder",
                title: "这里没有视频",
                message: "当前目录没有子文件夹，也没有支持的视频文件。"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.entries) { entry in
                        row(entry)
                    }
                }
                .padding(16)
            }
        }
    }

    private func row(_ entry: SMBEntry) -> some View {
        Button {
            if entry.isDirectory {
                model.enter(entry)
            } else if let url = access.playbackURL(relativePath: entry.path) {
                playRequest = PlayRequest(url: url, title: entry.name)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "film")
                    .font(.system(size: 16))
                    .foregroundColor(entry.isDirectory ? CF.accent : CF.text3)
                    .frame(width: 26)

                Text(entry.name)
                    .font(CF.ui(CF.fontBody))
                    .foregroundColor(CF.text1)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if entry.isDirectory {
                    Text("文件夹")
                        .font(CF.mono(CF.fontCaption))
                        .foregroundColor(CF.text3)
                } else {
                    Text(Entry.formatSize(entry.size))
                        .font(CF.mono(CF.fontCaption))
                        .foregroundColor(CF.text3)
                    Image(systemName: "play.circle")
                        .font(.system(size: 16))
                        .foregroundColor(CF.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model

@MainActor
final class SMBBrowserModel: ObservableObject {
    @Published var entries: [SMBEntry] = []
    @Published var path = ""
    @Published var isLoading = false
    @Published var error: String?
    @Published var connected = false

    private var client: SMBClient?

    func open(access: SMBAccess) async {
        guard client == nil else { return }
        guard let client = SMBClient(access: access) else {
            error = "无法创建 SMB 连接：地址或凭据格式不正确。"
            return
        }
        self.client = client
        isLoading = true
        do {
            try await client.connect()
            connected = true
            let all = try await client.list("")
            entries = all.filter { $0.isDirectory || DirectoryLister.isVideo($0.name) }
        } catch {
            self.error = "连接 \(access.server) 失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    func load(_ newPath: String) async {
        guard let client, connected else { return }
        isLoading = true
        error = nil
        do {
            let all = try await client.list(newPath)
            entries = all.filter { $0.isDirectory || DirectoryLister.isVideo($0.name) }
            path = newPath
        } catch {
            self.error = "读取目录失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    func enter(_ entry: SMBEntry) {
        guard entry.isDirectory else { return }
        Task { await load(entry.path) }
    }

    func goUp() {
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        Task { await load(parent) }
    }
}
