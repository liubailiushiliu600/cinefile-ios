import Foundation
import SwiftUI

/// One speed measurement: read a chunk of the largest video in a folder and
/// time it. Works for local folders and for SMB locations mounted by the
/// system Files app, because both go through FileHandle.
struct SpeedSample: Sendable {
    let fileName: String
    let fileSize: Int64
    let bytesRead: Int64
    let seconds: Double
    let firstByteSeconds: Double

    var megabytesPerSecond: Double {
        seconds > 0 ? Double(bytesRead) / seconds / 1024 / 1024 : 0
    }

    var firstByteMilliseconds: Double {
        firstByteSeconds * 1000
    }

    var readLabel: String {
        ByteCountFormatter.string(fromByteCount: bytesRead, countStyle: .file)
    }

    var fileLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

enum SpeedTestError: LocalizedError {
    case noLibrary
    case noVideo
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noLibrary:
            return "请先在主界面打开一个文件夹，再回来测速。"
        case .noVideo:
            return "这个文件夹里没有找到视频文件，换个目录再试。"
        case .readFailed(let message):
            return "读取失败：\(message)"
        }
    }
}

enum SpeedTester {
    static let sampleBytes: Int64 = 32 * 1024 * 1024

    /// The largest video file under a folder (bounded scan, depth 4).
    static func largestVideo(in folder: URL, maxEntries: Int = 800) -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var best: URL?
        var bestSize: Int64 = -1
        var seen = 0

        while let url = enumerator.nextObject() as? URL {
            seen += 1
            if seen > maxEntries { break }
            if enumerator.level > 4 { enumerator.skipDescendants() }
            guard DirectoryLister.isVideo(url.lastPathComponent) else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if size > bestSize {
                bestSize = size
                best = url
            }
        }
        return best
    }

    static func run(folder: URL, limit: Int64 = sampleBytes) throws -> SpeedSample {
        guard let url = largestVideo(in: folder) else {
            throw SpeedTestError.noVideo
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SpeedTestError.readFailed(error.localizedDescription)
        }
        defer { try? handle.close() }

        let target = fileSize > 0 ? min(limit, fileSize) : limit
        let start = CFAbsoluteTimeGetCurrent()

        var total: Int64 = 0
        var firstByteSeconds = 0.0

        do {
            let first = try handle.read(upToCount: 64 * 1024) ?? Data()
            firstByteSeconds = CFAbsoluteTimeGetCurrent() - start
            total += Int64(first.count)

            let chunkSize = 1024 * 1024
            while total < target {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                total += Int64(chunk.count)
            }
        } catch {
            throw SpeedTestError.readFailed(error.localizedDescription)
        }

        let elapsed = max(CFAbsoluteTimeGetCurrent() - start, 0.001)
        guard total > 0 else {
            throw SpeedTestError.readFailed("没有读到数据")
        }

        return SpeedSample(
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            bytesRead: total,
            seconds: elapsed,
            firstByteSeconds: firstByteSeconds
        )
    }
}

// MARK: - View

struct SpeedTestView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case idle
        case running
        case done(SpeedSample)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @State private var phase: Phase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            target
            result
            Spacer(minLength: 0)
            actions
        }
        .padding(26)
        .frame(minWidth: 520, minHeight: 520, alignment: .topLeading)
        .background(CF.bg0)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("连接速度测试")
                    .font(CF.ui(26, weight: .semibold))
                    .foregroundColor(CF.text1)
                Text("读取当前文件夹里最大的视频，测 iPad 到文件所在位置的读取速度。")
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

    private var target: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 15))
                .foregroundColor(CF.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.currentURL?.lastPathComponent ?? "未打开文件夹")
                    .font(CF.ui(CF.fontBody, weight: .medium))
                    .foregroundColor(CF.text1)
                Text(app.currentURL?.path ?? "先回到主界面打开一个文件夹")
                    .font(CF.mono(11))
                    .foregroundColor(CF.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: CF.radiusSmall).fill(CF.bg2))
    }

    @ViewBuilder
    private var result: some View {
        switch phase {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("点击下方「开始测速」。")
                    .font(CF.ui(CF.fontBody))
                    .foregroundColor(CF.text2)
                Text("会读取最多 32 MB 数据，不会修改任何文件。")
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: CF.radius).fill(CF.bg1))

        case .running:
            HStack(spacing: 12) {
                ProgressView().tint(CF.accent)
                Text("正在读取，网络位置可能需要几秒…")
                    .font(CF.ui(CF.fontBody))
                    .foregroundColor(CF.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: CF.radius).fill(CF.bg1))

        case .done(let sample):
            doneView(sample)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("测速失败")
                    .font(CF.ui(CF.fontBody, weight: .semibold))
                    .foregroundColor(CF.danger)
                Text(message)
                    .font(CF.ui(CF.fontSmall))
                    .foregroundColor(CF.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: CF.radius).fill(CF.bg1))
        }
    }

    private func doneView(_ sample: SpeedSample) -> some View {
        let verdict = Self.verdict(sample.megabytesPerSecond)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.1f", sample.megabytesPerSecond))
                    .font(CF.mono(52, weight: .semibold))
                    .foregroundColor(CF.text1)
                Text("MB/s")
                    .font(CF.mono(16))
                    .foregroundColor(CF.text3)
                Spacer(minLength: 0)
                Text(verdict.label)
                    .font(CF.ui(CF.fontSmall, weight: .semibold))
                    .foregroundColor(verdict.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(verdict.color.opacity(0.14))
                    )
            }

            Text(verdict.detail)
                .font(CF.ui(CF.fontSmall))
                .foregroundColor(CF.text2)

            Hairline()

            VStack(spacing: 8) {
                metricRow("首字节延迟", String(format: "%.0f ms", sample.firstByteMilliseconds))
                metricRow("读取量", "\(sample.readLabel) / \(sample.fileLabel)")
                metricRow("测试文件", sample.fileName)
                metricRow("耗时", String(format: "%.2f s", sample.seconds))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CF.radius).fill(CF.bg1))
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(CF.ui(CF.fontSmall))
                .foregroundColor(CF.text3)
            Spacer(minLength: 12)
            Text(value)
                .font(CF.mono(CF.fontSmall))
                .foregroundColor(CF.text1)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                runTest()
            } label: {
                Label(phase.isRunning ? "测速中…" : "开始测速", systemImage: "speedometer")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(CFButtonStyle(primary: true))
            .disabled(phase.isRunning || app.currentURL == nil)

            Button("完成") { dismiss() }
                .buttonStyle(CFButtonStyle())
        }
    }

    // MARK: Actions

    private func runTest() {
        guard let folder = app.currentURL else {
            phase = .failed(SpeedTestError.noLibrary.errorDescription ?? "")
            return
        }
        phase = .running
        Task {
            do {
                let sample = try await Task.detached(priority: .userInitiated) {
                    try SpeedTester.run(folder: folder)
                }.value
                phase = .done(sample)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(message)
            }
        }
    }

    private static func verdict(_ mbps: Double) -> (label: String, color: Color, detail: String) {
        if mbps >= 20 {
            return ("4K 原盘无压力", CF.success, "带宽充足，高码率 4K 也能直接播放。")
        }
        if mbps >= 10 {
            return ("4K 流畅", CF.success, "4K 播放没问题，拖动进度条也会比较跟手。")
        }
        if mbps >= 5 {
            return ("1080p 流畅", CF.accent, "1080p 稳定；4K 高码率可能会缓冲。")
        }
        if mbps >= 1.5 {
            return ("1080p 可能卡顿", CF.danger, "建议靠近路由器，或换 5 GHz / 有线网络。")
        }
        return ("带宽不足", CF.danger, "检查 Wi-Fi 信号，或把视频拷到本机再看。")
    }
}
