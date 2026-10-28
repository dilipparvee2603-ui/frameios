import Foundation
import ffmpegkit

/// Probed media metadata extracted before remuxing
private struct ProbedMediaInfo {
    var durationSec: Double = 0.0
    var isHEVC: Bool = false
    var isVP9: Bool = false
    var videoCodec: String = ""
    var audioCodec: String = ""
}

/// Ultra-fast container remuxer that repackages Matroska (.mkv) and WebM (.webm)
/// files into native Apple QuickTime/MP4 containers with real-time percentage progress.
///
/// Performance & Compatibility Features:
/// 1. Direct stream-copy for video with automatic `-tag:v hvc1` tagging for HEVC (prevents Apple AVPlayer black screen).
/// 2. Stream-copies compatible audio (AAC/AC3/MP3) with automatic Tier-2 AAC fallback for exotic audio (DTS/Opus/FLAC).
/// 3. Applies `-movflags +faststart` to place MOOV atom at file beginning for instant frame rendering and scrubbing in AVPlayer.
/// 4. Multithreaded execution (`-threads 0`) utilizing all Apple Silicon high-performance cores.
final class MKVRemuxEngine {
    static let shared = MKVRemuxEngine()
    private init() {}

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
                        if codec.contains("hevc") || codec.contains("h265") || codec.contains("hev") || codec.contains("hvc") {
                            info.isHEVC = true
                        } else if codec.contains("vp9") || codec.contains("vp8") {
                            info.isVP9 = true
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
                    } else if output.contains("vp9") || output.contains("vp8") {
                        info.isVP9 = true
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
            // If the container has VP9/VP8 video (common in YouTube WebM), iOS AVPlayer cannot decode it natively.
            // Transcode video to standard H.264 so AVPlayer renders it perfectly.
            if probedInfo.isVP9 {
                let vp9Arguments = [
                    "-threads", "0",
                    "-y",
                    "-i", sourceUrl.path,
                    "-map", "0:v:0",
                    "-map", "0:a:0?",
                    "-c:v", "libx264",
                    "-preset", "ultrafast",
                    "-crf", "22",
                    "-c:a", "aac",
                    "-b:a", "192k",
                    "-movflags", "+faststart",
                    outputUrl.path
                ]

                let session = FFmpegKit.execute(withArguments: vp9Arguments)
                let code = session?.getReturnCode()
                if ReturnCode.isSuccess(code),
                   FileManager.default.fileExists(atPath: outputUrl.path),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: outputUrl.path),
                   (attrs[.size] as? Int64 ?? 0) > 1024 {
                    onProgress?(1.0, "Complete")
                    return outputUrl
                }
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
