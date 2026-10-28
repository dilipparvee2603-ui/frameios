import Foundation
import ffmpegkit

/// Probed media metadata extracted before remuxing
private struct ProbedMediaInfo {
    var durationSec: Double = 0.0
    var width: Int = 0
    var height: Int = 0
    var isHEVC: Bool = false
    var isH264: Bool = false
    var isVP: Bool = false
    var isAV1: Bool = false
    var videoCodec: String = ""
    var audioCodec: String = ""
}

/// Ultra-fast container remuxer that repackages Matroska (.mkv) and WebM (.webm)
/// files into native Apple QuickTime/MP4 containers with real-time percentage progress.
///
/// Performance & Compatibility Features:
/// 1. Direct stream-copy for video with automatic `-tag:v hvc1` tagging for HEVC (prevents Apple AVPlayer black screen).
/// 2. Stream-copies compatible audio (AAC/AC3/MP3) with automatic Tier-2 AAC fallback for exotic audio (DTS/Opus/FLAC).
/// 3. Resilient WebM transcode using Apple hardware `h264_videotoolbox` with automatic `mpeg4` fallback (zero missing encoder failures).
/// 4. Applies `-movflags +faststart` to place MOOV atom at file beginning for instant frame rendering and scrubbing in AVPlayer.
/// 5. Multithreaded execution (`-threads 0`) utilizing all Apple Silicon high-performance cores.
final class MKVRemuxEngine {
    static let shared = MKVRemuxEngine()
    private init() {}

    /// Cancels any active FFmpeg remuxing or transcoding operation
    func cancel() {
        FFmpegKit.cancel()
    }

    private static var cachedSupportedVideoEncoder: String? = nil

    /// Detects the highest-performing video encoder supported by the runtime FFmpeg build
    private static func getBestVideoEncoder() -> String {
        if let cached = cachedSupportedVideoEncoder {
            return cached
        }
        if let session = FFmpegKit.execute("-encoders"),
           let output = session.getAllLogsAsString() ?? session.getOutput() {
            if output.contains("h264_videotoolbox") {
                cachedSupportedVideoEncoder = "h264_videotoolbox"
                return "h264_videotoolbox"
            }
            if output.contains("libx264") {
                cachedSupportedVideoEncoder = "libx264"
                return "libx264"
            }
        }
        // Native MPEG-4 Part 2 is built into every libavcodec binary and natively decoded by iOS AVPlayer
        cachedSupportedVideoEncoder = "mpeg4"
        return "mpeg4"
    }

    /// Constructs studio-grade transcode arguments with adaptive high bitrate for pristine, visual-lossless quality
    private static func buildTranscodeArgs(
        sourceUrl: URL,
        outputUrl: URL,
        encoder: String,
        width: Int,
        height: Int,
        hasAudio: Bool
    ) -> [String] {
        var args = [
            "-threads", "0",
            "-y",
            "-i", sourceUrl.path,
            "-map", "0:v:0",
            "-map_metadata", "0",
            "-c:v", encoder,
            "-pix_fmt", "yuv420p"
        ]

        if encoder == "h264_videotoolbox" {
            // Adaptive ultra-high bitrate matching Apple ProRes/AVFoundation master profiles
            let targetBitrate: String
            let maxBitrate: String
            if width >= 3840 || height >= 2160 {
                targetBitrate = "45M"
                maxBitrate = "65M"
            } else if width >= 1920 || height >= 1080 {
                targetBitrate = "24M"
                maxBitrate = "32M"
            } else if width >= 1280 || height >= 720 {
                targetBitrate = "14M"
                maxBitrate = "20M"
            } else {
                targetBitrate = "10M"
                maxBitrate = "15M"
            }

            args += [
                "-b:v", targetBitrate,
                "-maxrate", maxBitrate,
                "-profile:v", "high",
                "-allow_sw", "1",
                "-colorspace", "1",
                "-color_primaries", "1",
                "-color_trc", "1"
            ]
        } else if encoder == "libx264" {
            args += [
                "-preset", "veryfast",
                "-crf", "17",
                "-colorspace", "1",
                "-color_primaries", "1",
                "-color_trc", "1"
            ]
        } else if encoder == "mpeg4" {
            // Quality scale 1 is pristine maximum quality for native MPEG-4
            args += ["-q:v", "1"]
        }

        if hasAudio {
            args += [
                "-map", "0:a:0?",
                "-c:a", "aac",
                "-b:a", "320k"
            ]
        } else {
            args += ["-an"]
        }

        args += [
            "-movflags", "+faststart",
            outputUrl.path
        ]
        return args
    }

    /// Checks if a given file URL points to a Matroska or WebM container
    func isMatroska(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mkv" || ext == "webm"
    }

    /// Remuxes an MKV or WebM video file to an Apple-compatible MP4 container.
    ///
    /// - Parameters:
    ///   - sourceUrl: The local file URL of the source .mkv or .webm video.
    ///   - onProgress: Closure receiving normalized progress (0.0 ... 1.0) and current speed text (e.g., "45.0x").
    /// - Returns: The URL of the resulting .mp4 file stored in the temporary directory.
    func remuxToMP4(
        sourceUrl: URL,
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> URL {
        let baseName = sourceUrl.deletingPathExtension().lastPathComponent
        let sanitizedBaseName = baseName.isEmpty ? "movie" : baseName
        let outputUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitizedBaseName)_remuxed.mp4")

        try? FileManager.default.removeItem(at: outputUrl)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sourceUrl.path)[.size] as? Int64) ?? 0

        // Asynchronously probe duration and codec info with a 3.0s timeout
        let probeTask = Task.detached(priority: .userInitiated) { () -> ProbedMediaInfo in
            var info = ProbedMediaInfo()
            guard let session = FFprobeKit.getMediaInformation(sourceUrl.path),
                  let mediaInfo = session.getMediaInformation() else {
                return info
            }

            info.durationSec = Double(mediaInfo.getDuration() ?? "") ?? 0.0

            if let streams = mediaInfo.getStreams() {
                for case let stream as StreamInformation in streams {
                    let type = stream.getType()?.lowercased() ?? ""
                    let codec = stream.getCodec()?.lowercased() ?? ""
                    if type == "video" && info.videoCodec.isEmpty {
                        info.videoCodec = codec
                        if let w = (stream.getWidth() as? NSNumber)?.intValue, w > 0 {
                            info.width = w
                        }
                        if let h = (stream.getHeight() as? NSNumber)?.intValue, h > 0 {
                            info.height = h
                        }
                        if codec.contains("hevc") || codec.contains("h265") || codec.contains("hev") || codec.contains("hvc") {
                            info.isHEVC = true
                        } else if codec.contains("264") || codec.contains("avc") {
                            info.isH264 = true
                        } else if codec.contains("vp9") || codec.contains("vp8") {
                            info.isVP = true
                        } else if codec.contains("av1") || codec.contains("av01") {
                            info.isAV1 = true
                        }
                    } else if type == "audio" && info.audioCodec.isEmpty {
                        info.audioCodec = codec
                    }
                }
            }

            // Fallback: if video codec wasn't identified from stream array, run a quick direct probe command
            if info.videoCodec.isEmpty {
                let execSession = FFprobeKit.execute("-v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \"\(sourceUrl.path)\"")
                if let output = execSession?.getOutput()?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                    info.videoCodec = output
                    if output.contains("hevc") || output.contains("h265") || output.contains("hev") || output.contains("hvc") {
                        info.isHEVC = true
                    } else if output.contains("264") || output.contains("avc") {
                        info.isH264 = true
                    } else if output.contains("vp9") || output.contains("vp8") {
                        info.isVP = true
                    } else if output.contains("av1") || output.contains("av01") {
                        info.isAV1 = true
                    }
                }
            }

            return info
        }

        let probedInfo: ProbedMediaInfo
        if let result = try? await withThrowingTaskGroup(of: ProbedMediaInfo.self, body: { group -> ProbedMediaInfo in
            group.addTask {
                return await probeTask.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return ProbedMediaInfo()
            }
            let first = try await group.next() ?? ProbedMediaInfo()
            group.cancelAll()
            return first
        }) {
            probedInfo = result
        } else {
            probedInfo = ProbedMediaInfo()
        }

        let totalDurationMs = probedInfo.durationSec * 1000.0

        // Enable real-time statistics callback
        FFmpegKitConfig.enableStatisticsCallback { stats in
            guard let stats = stats else { return }
            let timeMs = Double(stats.getTime())
            let speedVal = stats.getSpeed()
            let speedText = speedVal > 0 ? String(format: "%.1fx", speedVal) : ""

            var fraction = 0.0
            if totalDurationMs > 0 {
                fraction = min(0.99, max(0.01, timeMs / totalDurationMs))
            } else if fileSize > 0 && stats.getSize() > 0 {
                fraction = min(0.99, max(0.01, Double(stats.getSize()) / Double(fileSize)))
            } else if timeMs > 0 {
                fraction = min(0.95, timeMs / 60000.0)
            }

            onProgress?(fraction, speedText)
        }

        defer {
            FFmpegKitConfig.enableStatisticsCallback(nil)
        }

        return try await Task.detached(priority: .userInitiated) {
            // Check if source video codec requires transcoding for Apple AVPlayer compatibility:
            // - WebM files (which typically use VP8, VP9, or AV1)
            // - Any container with VP8/VP9/AV1
            let isWebM = sourceUrl.pathExtension.lowercased() == "webm"
            let requiresTranscode = probedInfo.isVP || probedInfo.isAV1 || (isWebM && !probedInfo.isHEVC && !probedInfo.isH264)

            if requiresTranscode {
                onProgress?(0.05, "Converting WebM with Master Quality...")
                let primaryEncoder = MKVRemuxEngine.getBestVideoEncoder()
                let primaryArgs = MKVRemuxEngine.buildTranscodeArgs(
                    sourceUrl: sourceUrl,
                    outputUrl: outputUrl,
                    encoder: primaryEncoder,
                    width: probedInfo.width,
                    height: probedInfo.height,
                    hasAudio: !probedInfo.audioCodec.isEmpty
                )

                let session = FFmpegKit.execute(withArguments: primaryArgs)
                let code = session?.getReturnCode()

                if ReturnCode.isSuccess(code),
                   FileManager.default.fileExists(atPath: outputUrl.path),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: outputUrl.path),
                   (attrs[.size] as? Int64 ?? 0) > 1024 {
                    onProgress?(1.0, "Complete")
                    return outputUrl
                }

                // If primary encoder failed, try mpeg4 as safe fallback (present in every libavcodec)
                if primaryEncoder != "mpeg4" {
                    try? FileManager.default.removeItem(at: outputUrl)
                    let fallbackArgs = MKVRemuxEngine.buildTranscodeArgs(
                        sourceUrl: sourceUrl,
                        outputUrl: outputUrl,
                        encoder: "mpeg4",
                        width: probedInfo.width,
                        height: probedInfo.height,
                        hasAudio: !probedInfo.audioCodec.isEmpty
                    )
                    let fbSession = FFmpegKit.execute(withArguments: fallbackArgs)
                    let fbCode = fbSession?.getReturnCode()
                    if ReturnCode.isSuccess(fbCode),
                       FileManager.default.fileExists(atPath: outputUrl.path),
                       let attrs = try? FileManager.default.attributesOfItem(atPath: outputUrl.path),
                       (attrs[.size] as? Int64 ?? 0) > 1024 {
                        onProgress?(1.0, "Complete")
                        return outputUrl
                    }
                }

                let logs = session?.getAllLogsAsString() ?? session?.getFailStackTrace() ?? "WebM conversion failed"
                let lastLines = logs.split(separator: "\n").suffix(6).joined(separator: "\n")
                throw NSError(
                    domain: "MKVRemuxEngine",
                    code: Int(code?.getValue() ?? -1),
                    userInfo: [NSLocalizedDescriptionKey: "WebM conversion error:\n\(lastLines)"]
                )
            }

            // Tier 1: Pure Stream Copy (Both video and audio stream copied bit-for-bit).
            // IMPORTANT: If video is HEVC, tag as `hvc1` so Apple's AVPlayer/AVPlayerLayer can decode it (without this, iOS shows a black screen!).
            // Apply +faststart to move MOOV atom to file beginning for instant playback.
            var tier1Arguments = [
                "-threads", "0",
                "-y",
                "-i", sourceUrl.path,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-c:v", "copy"
            ]

            if probedInfo.isHEVC {
                tier1Arguments += ["-tag:v", "hvc1"]
            }

            tier1Arguments += [
                "-c:a", "copy",
                "-movflags", "+faststart",
                "-strict", "-2",
                outputUrl.path
            ]

            let tier1Session = FFmpegKit.execute(withArguments: tier1Arguments)
            let tier1Code = tier1Session?.getReturnCode()

            if ReturnCode.isSuccess(tier1Code),
               FileManager.default.fileExists(atPath: outputUrl.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: outputUrl.path),
               (attrs[.size] as? Int64 ?? 0) > 1024 {
                onProgress?(1.0, "Complete")
                return outputUrl
            }

            if ReturnCode.isCancel(tier1Code) {
                throw NSError(
                    domain: "MKVRemuxEngine",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Remux operation was cancelled."]
                )
            }

            // Tier 2 Fallback: If audio track is incompatible with direct copy (e.g. DTS, Vorbis, Opus, FLAC),
            // copy video 100% losslessly with `hvc1` tag and transcode audio to standard high-compatibility AAC.
            try? FileManager.default.removeItem(at: outputUrl)

            var tier2Arguments = [
                "-threads", "0",
                "-y",
                "-i", sourceUrl.path,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-c:v", "copy"
            ]

            if probedInfo.isHEVC {
                tier2Arguments += ["-tag:v", "hvc1"]
            }

            tier2Arguments += [
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart",
                outputUrl.path
            ]

            let tier2Session = FFmpegKit.execute(withArguments: tier2Arguments)
            let tier2Code = tier2Session?.getReturnCode()

            if ReturnCode.isSuccess(tier2Code),
               FileManager.default.fileExists(atPath: outputUrl.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: outputUrl.path),
               (attrs[.size] as? Int64 ?? 0) > 1024 {
                onProgress?(1.0, "Complete")
                return outputUrl
            } else if ReturnCode.isCancel(tier2Code) {
                throw NSError(
                    domain: "MKVRemuxEngine",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Remux operation was cancelled."]
                )
            } else {
                let logs = tier2Session?.getAllLogsAsString() ?? tier2Session?.getFailStackTrace() ?? "Unknown remux error"
                let lastLines = logs.split(separator: "\n").suffix(5).joined(separator: "\n")
                throw NSError(
                    domain: "MKVRemuxEngine",
                    code: Int(tier2Code?.getValue() ?? -1),
                    userInfo: [NSLocalizedDescriptionKey: "MKV Remux failed:\n\(lastLines)"]
                )
            }
        }.value
    }
}
