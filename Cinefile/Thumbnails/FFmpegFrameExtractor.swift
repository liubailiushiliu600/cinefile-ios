import AMSMB2
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import UIKit

/// Single-frame extraction through FFmpeg — the Infuse approach: seek to the
/// target timestamp, decode exactly one frame, scale it to RGB. No playback, no
/// audio, no video output.
///
/// FFmpeg's LGPL build has no SMB protocol, so bytes come from AMSMB2 through a
/// custom AVIO context. Reads are ranged `contents(atPath:range:)` calls; the
/// handle is reopened per read, which is the known cost of AMSMB2 not exposing
/// a persistent file handle.
enum FFmpegFrameExtractor {
    /// Must be called off the main thread: the AVIO read blocks on AMSMB2.
    static func extract(
        manager: SMB2Manager,
        path: String,
        fileSize: Int64,
        at seconds: Double,
        maxWidth: Int32 = 480
    ) -> UIImage? {
        guard fileSize > 0, maxWidth > 0 else { return nil }
        av_log_set_level(-8)  // AV_LOG_QUIET

        let reader = SMBByteReader(manager: manager, path: path, size: fileSize)
        return decode(reader: reader, seconds: seconds, maxWidth: maxWidth)
    }

    // MARK: - Decode

    private static func decode(reader: SMBByteReader, seconds: Double, maxWidth: Int32) -> UIImage? {
        let opaque = Unmanaged.passUnretained(reader).toOpaque()

        let ioBufferSize: Int32 = 64 * 1024
        guard let ioBuffer = av_malloc(Int(ioBufferSize)) else { return nil }

        guard let avio = avio_alloc_context(
            ioBuffer.assumingMemoryBound(to: UInt8.self),
            ioBufferSize,
            0,
            opaque,
            readPacket,
            nil,
            seekStream
        ) else {
            av_free(ioBuffer)
            return nil
        }
        var avioPointer: UnsafeMutablePointer<AVIOContext>? = avio

        guard let format = avformat_alloc_context() else {
            avio_context_free(&avioPointer)
            return nil
        }
        // We own the AVIO buffer; tell avformat not to free it for us.
        format.pointee.flags |= 0x80  // AVFMT_FLAG_CUSTOM_IO
        format.pointee.pb = avio

        var formatPointer: UnsafeMutablePointer<AVFormatContext>? = format
        guard avformat_open_input(&formatPointer, nil, nil, nil) >= 0, let fmt = formatPointer else {
            avformat_close_input(&formatPointer)
            avio_context_free(&avioPointer)
            return nil
        }
        defer {
            avformat_close_input(&formatPointer)
            avio_context_free(&avioPointer)
        }

        guard avformat_find_stream_info(fmt, nil) >= 0 else { return nil }

        let streamIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard streamIndex >= 0 else { return nil }

        guard
            let streams = fmt.pointee.streams,
            let stream = streams[Int(streamIndex)],
            let codecpar = stream.pointee.codecpar
        else {
            return nil
        }

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else { return nil }
        guard let codecContext = avcodec_alloc_context3(codec) else { return nil }
        var codecPointer: UnsafeMutablePointer<AVCodecContext>? = codecContext
        defer { avcodec_free_context(&codecPointer) }

        guard avcodec_parameters_to_context(codecContext, codecpar) >= 0 else { return nil }
        guard avcodec_open2(codecContext, codec, nil) >= 0 else { return nil }

        // Seek to the requested timestamp (stream time base).
        let timeBase = stream.pointee.time_base
        let timeScale = timeBase.den == 0 ? 1.0 : Double(timeBase.num) / Double(timeBase.den)
        let timestamp = Int64(seconds / timeScale)
        av_seek_frame(fmt, streamIndex, timestamp, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecContext)

        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else { return nil }
        var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
        var framePointer: UnsafeMutablePointer<AVFrame>? = frame
        defer {
            av_packet_free(&packetPointer)
            av_frame_free(&framePointer)
        }

        var decoded = false
        var attempts = 0
        while attempts < 400 {
            attempts += 1
            guard av_read_frame(fmt, packet) >= 0 else { break }

            if packet.pointee.stream_index == streamIndex {
                if avcodec_send_packet(codecContext, packet) >= 0 {
                    if avcodec_receive_frame(codecContext, frame) >= 0 {
                        decoded = true
                        av_packet_unref(packet)
                        break
                    }
                }
            }
            av_packet_unref(packet)
        }
        guard decoded else { return nil }

        return makeImage(frame: frame, maxWidth: maxWidth)
    }

    // MARK: - RGB conversion

    private static func makeImage(frame: UnsafeMutablePointer<AVFrame>, maxWidth: Int32) -> UIImage? {
        let width = frame.pointee.width
        let height = frame.pointee.height
        guard width > 0, height > 0 else { return nil }

        let outWidth = maxWidth
        let outHeight = max(1, Int32(Double(height) * Double(maxWidth) / Double(width)))
        let pixelFormat = AVPixelFormat(rawValue: frame.pointee.format)

        guard let scaler = sws_getContext(
            width,
            height,
            pixelFormat,
            outWidth,
            outHeight,
            AV_PIX_FMT_RGB24,
            Int32(bitPattern: SWS_BILINEAR.rawValue),
            nil,
            nil,
            nil
        ) else {
            return nil
        }
        defer { sws_freeContext(scaler) }

        let rgbSize = Int(outWidth * outHeight * 3)
        guard let rgb = av_malloc(rgbSize)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        defer { av_free(rgb) }

        var destination: [UnsafeMutablePointer<UInt8>?] = [rgb]
        var destinationStride: [Int32] = [outWidth * 3]

        // FFmpeg hands frames back as 8-element pointer tuples; copy them into
        // arrays so sws_scale gets the pointer shapes it expects.
        let planes = frame.pointee.data
        var sourceData: [UnsafePointer<UInt8>?] = [
            planes.0.map { UnsafePointer($0) },
            planes.1.map { UnsafePointer($0) },
            planes.2.map { UnsafePointer($0) },
            planes.3.map { UnsafePointer($0) },
            planes.4.map { UnsafePointer($0) },
            planes.5.map { UnsafePointer($0) },
            planes.6.map { UnsafePointer($0) },
            planes.7.map { UnsafePointer($0) }
        ]
        let strides = frame.pointee.linesize
        var sourceStride: [Int32] = [
            strides.0, strides.1, strides.2, strides.3,
            strides.4, strides.5, strides.6, strides.7
        ]

        sws_scale(scaler, &sourceData, &sourceStride, 0, height, &destination, &destinationStride)

        let data = Data(bytes: rgb, count: rgbSize)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: Int(outWidth),
            height: Int(outHeight),
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: Int(outWidth) * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - AVIO bridging

    private static let readPacket: @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32 = { opaque, buffer, size in
        guard let opaque, let buffer, size > 0 else { return 0 }
        let reader = Unmanaged<SMBByteReader>.fromOpaque(opaque).takeUnretainedValue()
        guard let data = reader.read(size), !data.isEmpty else { return 0 }
        data.copyBytes(to: buffer, count: data.count)
        return Int32(data.count)
    }

    private static let seekStream: @convention(c) (
        UnsafeMutableRawPointer?, Int64, Int32
    ) -> Int64 = { opaque, offset, whence in
        guard let opaque else { return -1 }
        let reader = Unmanaged<SMBByteReader>.fromOpaque(opaque).takeUnretainedValue()
        return reader.seek(offset, whence: whence)
    }
}

/// Byte source for the custom AVIO, backed by AMSMB2's ranged reads.
final class SMBByteReader {
    private let manager: SMB2Manager
    private let path: String
    let size: Int64
    private(set) var position: Int64 = 0

    init(manager: SMB2Manager, path: String, size: Int64) {
        self.manager = manager
        self.path = path
        self.size = size
    }

    func read(_ count: Int32) -> Data? {
        guard count > 0, position < size else { return nil }
        let end = min(size, position + Int64(count))
        guard end > position else { return nil }

        let start = position
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        Task {
            result = try? await manager.contents(
                atPath: path,
                range: UInt64(start)..<UInt64(end)
            )
            semaphore.signal()
        }
        semaphore.wait()

        guard let data = result else { return nil }
        position += Int64(data.count)
        return data
    }

    func seek(_ offset: Int64, whence: Int32) -> Int64 {
        let base: Int64
        switch whence {
        case 0: base = 0            // SEEK_SET
        case 1: base = position     // SEEK_CUR
        case 2: base = size         // SEEK_END
        default: return -1
        }
        let target = min(max(0, base + offset), size)
        position = target
        return target
    }
}
