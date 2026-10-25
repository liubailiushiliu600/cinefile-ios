import SwiftUI
import UniformTypeIdentifiers

/// iPad shell: sidebar (libraries + folder tree) + detail (browser or welcome).
struct RootView: View {
    @EnvironmentObject private var app: AppState
    @State private var showPicker = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showPicker: $showPicker)
                .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 320)
        } detail: {
            Group {
                if app.currentLibrary != nil {
                    BrowserView()
                } else {
                    WelcomeView(showPicker: $showPicker)
                }
            }
            .background(CF.bg0)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(CF.accent)
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
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var app: AppState
    @Binding var showPicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    librarySection
                    if app.currentLibrary != nil {
                        folderSection
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            Spacer(minLength: 0)
            Hairline()
            footer
        }
        .background(CF.bg1)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(CF.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("CINEFILE")
                    .font(CF.ui(13, weight: .bold))
                    .tracking(2.2)
                    .foregroundColor(CF.text1)
                Text("PRIVATE EDITION · 文件夹即片库")
                    .font(CF.mono(9))
                    .foregroundColor(CF.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Libraries · 片库")
            if app.libraries.isEmpty {
                Text("还没有片库。打开一个包含视频的文件夹即可开始。")
                    .font(CF.ui(12))
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
                    .font(CF.ui(12, weight: .medium))
                    .foregroundColor(CF.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: CF.radiusSmall)
                            .stroke(CF.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func libraryRow(_ ref: LibraryRef) -> some View {
        let active = app.currentLibrary?.id == ref.id
        return Button {
            app.open(ref)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 12))
                    .foregroundColor(active ? CF.accent : CF.text3)
                Text(ref.name)
                    .font(CF.ui(13, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? CF.text1 : CF.text2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: CF.radiusSmall)
                    .fill(active ? CF.bg3 : Color.clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CF.accent)
                        .frame(width: 3, height: 18)
                        .padding(.leading, 1)
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

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Folders · 文件夹")
            let folders = app.entries.filter { $0.isDirectory }
            if folders.isEmpty {
                Text("当前文件夹没有子文件夹")
                    .font(CF.ui(12))
                    .foregroundColor(CF.text3)
            } else {
                ForEach(folders) { entry in
                    Button {
                        app.navigate(to: entry.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                                .foregroundColor(CF.text3)
                            Text(entry.name)
                                .font(CF.ui(12))
                                .foregroundColor(CF.text2)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LOCAL · DIRECT PLAY")
            Text("NO SERVER · NO SCRAPING")
        }
        .font(CF.mono(9))
        .foregroundColor(CF.text3)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject private var app: AppState
    @Binding var showPicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CINEFILE")
                    .font(CF.ui(38, weight: .bold))
                    .tracking(4)
                    .foregroundColor(CF.text1)
                Text("文件夹即片库。不部署服务端，不刮削，不转码。")
                    .font(CF.ui(14))
                    .foregroundColor(CF.text2)
            }

            Button {
                showPicker = true
            } label: {
                Label("打开文件夹", systemImage: "folder.fill.badge.plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(CFButtonStyle(primary: true))

            if !app.libraries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Recent · 最近")
                    ForEach(app.libraries.prefix(3)) { ref in
                        Button {
                            app.open(ref)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundColor(CF.accent)
                                Text(ref.name)
                                    .foregroundColor(CF.text1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(CF.text3)
                            }
                            .font(CF.ui(13))
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg2))
                            .overlay(RoundedRectangle(cornerRadius: CF.radiusSmall).stroke(CF.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 460)
            }

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                Text("LOCAL FOLDER")
                Text("16:9 THUMBNAILS")
                Text("NATURAL SORT")
            }
            .font(CF.mono(10))
            .foregroundColor(CF.text3)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CF.bg0)
    }
}
