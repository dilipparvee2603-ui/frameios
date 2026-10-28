import Foundation
import ffmpegkit

/// High-performance container remuxer that repackages Matroska (.mkv) and WebM (.webm)
/// files into native Apple QuickTime/MP4 containers with real-time percentage progress.
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
    ///   - onProgress: Closure receiving normalized progress (0.0 ... 1.0) and current speed text (e.g., "35.4x").
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

        // Probe media duration to compute exact progress percentage
        let probeSession = FFprobeKit.getMediaInformation(sourceUrl.path)
        let mediaInfo = probeSession?.getMediaInformation()
        let durationSec = Double(mediaInfo?.getDuration() ?? "") ?? 0.0
        let totalDurationMs = durationSec * 1000.0

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sourceUrl.path)[.size] as? Int64) ?? 0

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

        // Stream-copy video track for instant 100% lossless conversion (preserves H.264/HEVC intact).
        // Transcode audio track to standard high-fidelity AAC (256k) to ensure full compatibility
        // across iOS AVPlayer (MKVs frequently contain AC3, DTS, Vorbis, Opus, or FLAC audio).
        // Apply +faststart to move MOOV atom to beginning for instant playback & scrubbing.
        let arguments = [
            "-y",
            "-i", sourceUrl.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "256k",
            "-movflags", "+faststart",
            outputUrl.path
        ]

        return try await Task.detached(priority: .userInitiated) {
            let session = FFmpegKit.execute(withArguments: arguments)
            guard let session = session else {
                throw NSError(
                    domain: "MKVRemuxEngine",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to initialize FFmpeg remux session."]
                )
            }

            let returnCode = session.getReturnCode()
            if ReturnCode.isSuccess(returnCode) {
                onProgress?(1.0, "Complete")
                // Verify that output file exists and is not empty
                guard FileManager.default.fileExists(atPath: outputUrl.path),
                      let attrs = try? FileManager.default.attributesOfItem(atPath: outputUrl.path),
                      (attrs[.size] as? Int64 ?? 0) > 0 else {
                    throw NSError(
                        domain: "MKVRemuxEngine",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Remuxed MP4 output is empty or was not created."]
                    )
                }
                return outputUrl
            } else if ReturnCode.isCancel(returnCode) {
                throw NSError(
                    domain: "MKVRemuxEngine",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Remux operation was cancelled."]
                )
            } else {
                let logs = session.getAllLogsAsString() ?? session.getFailStackTrace() ?? "Unknown remux error"
                let lastLines = logs.split(separator: "\n").suffix(5).joined(separator: "\n")
                throw NSError(
                    domain: "MKVRemuxEngine",
                    code: Int(returnCode?.getValue() ?? -1),
                    userInfo: [NSLocalizedDescriptionKey: "MKV Remux failed:\n\(lastLines)"]
                )
            }
        }.value
    }
}
