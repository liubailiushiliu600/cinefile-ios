import SwiftUI

/// The folder browser: breadcrumbs, toolbar, and the 16:9 thumbnail grid.
struct BrowserView: View {
    @EnvironmentObject private var app: AppState
    @AppStorage("gridColumns") private var columns: Int = 2

    private var gridItems: [GridItem] {
        let count = max(1, min(columns, 5))
        return Array(repeating: GridItem(.flexible(), spacing: CF.gap), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumbBar
            Hairline()
            toolbar
            Hairline()
            content
        }
        .background(CF.bg0)
    }

    // MARK: - Breadcrumbs

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(app.breadcrumbs.enumerated()), id: \.offset) { index, item in
                    Button {
                        app.navigate(to: item.url)
                    } label: {
                        Text(item.name)
                            .font(CF.mono(12))
                            .foregroundColor(index == app.breadcrumbs.count - 1 ? CF.text1 : CF.text3)
                    }
                    .buttonStyle(.plain)

                    if index < app.breadcrumbs.count - 1 {
                        Text("/")
                            .font(CF.mono(12))
                            .foregroundColor(CF.lineStrong)
                    }
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.currentTitle)
                    .font(CF.ui(28, weight: .semibold))
                    .foregroundColor(CF.text1)
                    .lineLimit(1)
                Text("\(app.folderCount) 个文件夹 · \(app.videoCount) 个视频 · 文件夹优先")
                    .font(CF.mono(12))
                    .foregroundColor(CF.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            searchField

            Button {
                app.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(CFButtonStyle())

            columnsPicker
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(CF.text3)
            TextField("搜索当前文件夹", text: $app.searchText)
                .textFieldStyle(.plain)
                .font(CF.ui(14))
                .foregroundColor(CF.text1)
                .frame(width: 190)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg0))
        .overlay(
            RoundedRectangle(cornerRadius: CF.radiusSmall)
                .stroke(CF.line, lineWidth: 1)
        )
    }

    private var columnsPicker: some View {
        HStack(spacing: 2) {
            ForEach([2, 3, 4], id: \.self) { value in
                Button {
                    columns = value
                } label: {
                    Text("\(value)")
                        .font(CF.mono(12, weight: .medium))
                        .foregroundColor(columns == value ? CF.text1 : CF.text3)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(columns == value ? CF.bg3 : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg0))
        .overlay(RoundedRectangle(cornerRadius: CF.radiusSmall).stroke(CF.line, lineWidth: 1))
    }

    // MARK: - Grid

    private var content: some View {
        ScrollView {
            if app.isLoading {
                ProgressView()
                    .tint(CF.text3)
                    .padding(60)
            } else if app.filteredEntries.isEmpty {
                emptyView
            } else {
                LazyVGrid(columns: gridItems, alignment: .leading, spacing: CF.gap) {
                    ForEach(app.filteredEntries) { entry in
                        Button {
                            app.play(entry)
                        } label: {
                            VideoCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
    }

    private var emptyView: some View {
        Group {
            if app.searchText.isEmpty {
                EmptyStateView(
                    systemImage: "folder",
                    title: "这个文件夹是空的",
                    message: "没有子文件夹，也没有支持的视频文件。\n支持的格式：mkv / mp4 / avi / ts / webm / rmvb 等。"
                )
            } else {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "没有匹配的内容",
                    message: "当前文件夹里没有名称包含「\(app.searchText)」的文件或文件夹。"
                )
            }
        }
    }
}
