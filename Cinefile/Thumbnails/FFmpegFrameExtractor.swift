// FFmpeg single-frame extraction was attempted (branch B) and removed.
//
// Why it is gone:
//  - FFmpegKit's prebuilt Libav* frameworks are dynamic frameworks with their
//    own _CodeSignature; after ldid re-signing, dyld still rejected the bundle
//    on TrollStore (instant crash, error 3).
//  - Even if it had loaded, AMSMB2 does not expose a persistent SMB file
//    handle, so every AVIO read reopened the file, eating most of the gain.
//  - The extra 10 MB and the second decoding stack were not worth the risk.
//
// Thumbnails now always go through RemoteThumbnailService's VLC capture queue,
// which is single-instance and memory-capped for 3 GB iPads.
