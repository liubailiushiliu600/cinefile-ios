import SwiftUI
import UIKit

/// 16:9 card: thumbnail (or folder art), name, size, rating slot.
struct VideoCard: View {
    let entry: Entry

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            info
        }
        .background(CF.bg2)
        .clipShape(RoundedRectangle(cornerRadius: CF.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CF.radius)
                .stroke(CF.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: CF.radius))
        .task(id: entry.id) {
            guard !entry.isDirectory else { return }
            if let loaded = await ThumbnailService.shared.thumbnail(for: entry) {
                image = loaded
            } else {
                failed = true
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle()
                .fill(CF.bg3)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if entry.isDirectory {
                Image(systemName: "folder.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(CF.text3.opacity(0.65))
            } else if failed {
                Image(systemName: "film")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(CF.text3)
            } else {
                ProgressView()
                    .tint(CF.text3)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) {
            if !entry.isDirectory {
                Text(entry.url.pathExtension.uppercased())
                    .font(CF.mono(9, weight: .medium))
                    .foregroundColor(CF.text1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(8)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name)
                .font(CF.ui(13, weight: .medium))
                .foregroundColor(CF.text1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if entry.isDirectory {
                    Text("文件夹")
                        .font(CF.mono(10))
                        .foregroundColor(CF.text3)
                } else {
                    Text(entry.displaySize)
                        .font(CF.mono(10))
                        .foregroundColor(CF.text3)
                }
                Spacer(minLength: 0)
                if !entry.isDirectory {
                    CFBadge(text: "未看", color: CF.stateUnwatched)
                }
            }
        }
        .padding(10)
    }
}
