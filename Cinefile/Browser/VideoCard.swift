import SwiftUI
import UIKit

/// 16:9 card: thumbnail (or format placeholder), name, size, rating slot.
/// Used for both local files and files on a paired peer's share.
struct VideoCard: View {
    let entry: Entry

    @EnvironmentObject private var app: AppState
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            info
        }
        .background(CF.bg2)
        .clipShape(RoundedRectangle(cornerRadius: CF.radius))
        .contentShape(RoundedRectangle(cornerRadius: CF.radius))
        .task(id: entry.id) {
            guard !entry.isDirectory else { return }

            if entry.isRemote {
                guard let client = app.activeSMBClient, let access = app.activeSMBAccess else { return }
                if let loaded = await RemoteThumbnailService.shared.thumbnail(for: entry, client: client, access: access) {
                    image = loaded
                } else {
                    failed = true
                }
            } else if let loaded = await ThumbnailService.shared.thumbnail(for: entry) {
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
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(CF.text3.opacity(0.65))
            } else if entry.isRemote {
                // SMB thumbnails are decoded by briefly playing the file, so
                // show a format plate with a small spinner until the frame lands.
                VStack(spacing: 7) {
                    Image(systemName: "film")
                        .font(.system(size: 30, weight: .light))
                    Text(entry.fileExtension.uppercased())
                        .font(CF.mono(11, weight: .medium))
                }
                .foregroundColor(CF.text3)
                .overlay(alignment: .bottomTrailing) {
                    if !failed {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(CF.text3)
                            .padding(8)
                    }
                }
            } else if failed {
                Image(systemName: "film")
                    .font(.system(size: 30, weight: .light))
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
                HStack(spacing: 4) {
                    if entry.isRemote {
                        Image(systemName: "network")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    Text(entry.fileExtension.uppercased())
                        .font(CF.mono(10, weight: .medium))
                }
                .foregroundColor(CF.text1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.6))
                )
                .padding(8)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.name)
                .font(CF.ui(15, weight: .medium))
                .foregroundColor(CF.text1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if entry.isDirectory {
                    Text("文件夹")
                        .font(CF.mono(12))
                        .foregroundColor(CF.text3)
                } else {
                    Text(entry.displaySize)
                        .font(CF.mono(12))
                        .foregroundColor(CF.text3)
                }
                Spacer(minLength: 0)
                if !entry.isDirectory {
                    CFBadge(text: "未看", color: CF.stateUnwatched)
                }
            }
        }
        .padding(12)
    }
}
