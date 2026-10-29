import Foundation
import AVFoundation
import Photos
import UIKit
import ffmpegkit

// MARK: - Stitch Clip Item Model
struct StitchClipItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let filename: String
    var durationMs: Int64
    var width: Int
    var height: Int
    var videoCodec: String
    var audioCodec: String
    var fps: Double
    var thumbnail: UIImage?

    var durationFormatted: String {
        let totalSeconds = Double(durationMs) / 1000.0
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let fraction = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, fraction)
    }

    var resolutionLabel: String {
        if width > 0 && height > 0 {
            return "\(width)×\(height)"
        }
        return "Unknown Res"
    }

    static func == (lhs: StitchClipItem, rhs: StitchClipItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Stitch Mode
enum StitchMode: String, CaseIterable, Identifiable {
    case lossless = "Lossless Stream-Copy (0% Loss)"
    case smartMatch = "Smart Match (Auto-Normalize)"

    var id: String { rawValue }

    var badge: String {
        switch self {
        case .lossless: return "⚡ 0% LOSS (INSTANT)"
        case .smartMatch: return "🔄 SMART RE-ENCODE"
        }
    }

    var description: String {
        switch self {
        case .lossless:
            return "Concatenates streams without re-encoding. 100% bit-for-bit quality preserved in under 2 seconds. Requires identical video codecs & resolution."
        case .smartMatch:
            return "Normalizes clips with differing resolutions or frame rates to match Clip #1 using Apple VideoToolbox hardware acceleration."
        }
    }
}

// MARK: - Stitch Result
struct StitchResult {
    let success: Bool
    let outputUrl: URL?
    let durationMs: Int64
    let isLosslessCopy: Bool
    let errorMessage: String?
}

// MARK: - Video Stitch Engine
final class VideoStitchEngine {
    static let shared = VideoStitchEngine()
    private var isCancelled: Bool = false

    private init() {}

    func cancel() {
        isCancelled = true
        FFmpegKit.cancel()
    }

    /// Probes a video URL to construct a StitchClipItem
    func probeClip(url: URL) async -> StitchClipItem {
        let filename = url.lastPathComponent
        let asset = AVURLAsset(url: url)

        var durationMs: Int64 = 0
        var width: Int = 0
        var height: Int = 0
        var fps: Double = 30.0
        var videoCodec: String = "h264"
        var audioCodec: String = "aac"

        if let dur = try? await asset.load(.duration) {
            durationMs = Int64(dur.seconds * 1000.0)
        }

        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await videoTrack.load(.naturalSize) {
                let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
                width = Int(isPortrait ? size.height : size.width)
                height = Int(isPortrait ? size.width : size.height)
            }
            if let nominalRate = try? await videoTrack.load(.nominalFrameRate), nominalRate > 0 {
                fps = Double(nominalRate)
            }
            if let formatDescriptions = try? await videoTrack.load(.formatDescriptions) {
                if let firstDesc = formatDescriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    videoCodec = fourCharCodeToString(subType)
                }
            }
        }

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            if let formatDescriptions = try? await audioTrack.load(.formatDescriptions) {
                if let firstDesc = formatDescriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    audioCodec = fourCharCodeToString(subType)
                }
            }
        }

        let thumbnail = await generateThumbnail(for: url)

        return StitchClipItem(
            id: UUID(),
            url: url,
            filename: filename,
            durationMs: durationMs,
            width: width,
            height: height,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            fps: fps,
            thumbnail: thumbnail
        )
    }

    /// Checks if a list of clips can be stitched using 100% lossless stream copy
    func canLosslessStitch(clips: [StitchClipItem]) -> (canLossless: Bool, reason: String) {
        guard clips.count >= 2 else {
            return (false, "Add at least 2 clips to merge")
        }

        let first = clips[0]
        for (idx, clip) in clips.enumerated() {
            if clip.width != first.width || clip.height != first.height {
                return (false, "Resolution mismatch (Clip #1 is \(first.width)×\(first.height), but Clip #\(idx + 1) is \(clip.width)×\(clip.height)). Use Smart Match.")
            }
            let c1 = normalizedCodec(first.videoCodec)
            let c2 = normalizedCodec(clip.videoCodec)
            if c1 != c2 && c1 != "unknown" && c2 != "unknown" {
                return (false, "Codec mismatch (Clip #1 is \(first.videoCodec), Clip #\(idx + 1) is \(clip.videoCodec)). Use Smart Match.")
            }
        }

        return (true, "100% Stream-Copy Ready (Zero Quality Loss)")
    }

    /// Performs concatenation of multiple clips into a single video file
    func stitchVideos(
        clips: [StitchClipItem],
        mode: StitchMode,
        onProgress: @escaping (Float, String) -> Void
    ) async -> StitchResult {
        guard clips.count >= 2 else {
            return StitchResult(success: false, outputUrl: nil, durationMs: 0, isLosslessCopy: false, errorMessage: "At least 2 clips are required")
        }

        isCancelled = false
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let outputUrl = tempDir.appendingPathComponent("CFX_Stitched_\(timestamp).mp4")
        try? FileManager.default.removeItem(at: outputUrl)

        let totalDurationMs = clips.reduce(0) { $0 + $1.durationMs }
        let totalDurationSec = max(0.5, Double(totalDurationMs) / 1000.0)

        // Decide execution path
        let (losslessPossible, _) = canLosslessStitch(clips: clips)
        let useLossless = (mode == .lossless && losslessPossible)

        if useLossless {
            return await runLosslessConcat(
                clips: clips,
                outputUrl: outputUrl,
                totalDurationMs: totalDurationMs,
                onProgress: onProgress
            )
        } else {
            return await runSmartMatchConcat(
                clips: clips,
                outputUrl: outputUrl,
                totalDurationSec: totalDurationSec,
                totalDurationMs: totalDurationMs,
                onProgress: onProgress
            )
        }
    }

    // MARK: - Lossless Concat Demuxer (-c copy)
    private func runLosslessConcat(
        clips: [StitchClipItem],
        outputUrl: URL,
        totalDurationMs: Int64,
        onProgress: @escaping (Float, String) -> Void
    ) async -> StitchResult {
        let tempDir = FileManager.default.temporaryDirectory
        let listFile = tempDir.appendingPathComponent("concat_list_\(UUID().uuidString).txt")

        // Write FFmpeg concat list
        var listContent = ""
        for clip in clips {
            let escapedPath = clip.url.path.replacingOccurrences(of: "'", with: "'\\''")
            listContent += "file '\(escapedPath)'\n"
        }

        do {
            try listContent.write(to: listFile, atomically: true, encoding: .utf8)
        } catch {
            return StitchResult(success: false, outputUrl: nil, durationMs: 0, isLosslessCopy: true, errorMessage: "Failed to write concat manifest: \(error.localizedDescription)")
        }

        defer {
            try? FileManager.default.removeItem(at: listFile)
        }

        let isHEVC = clips.first?.videoCodec.lowercased().contains("hevc") == true ||
                     clips.first?.videoCodec.lowercased().contains("hvc1") == true

        var cmd = "-f concat -safe 0 -i \"\(listFile.path)\" -c copy"
        if isHEVC {
            cmd += " -tag:v hvc1"
        }
        cmd += " -movflags +faststart -y \"\(outputUrl.path)\""

        onProgress(0.1, "Initializing lossless stream copy...")

        let session = FFmpegKit.execute(cmd)
        let returnCode = session?.getReturnCode()

        if ReturnCode.isSuccess(returnCode) && FileManager.default.fileExists(atPath: outputUrl.path) {
            onProgress(1.0, "Stitch completed losslessly!")
            return StitchResult(
                success: true,
                outputUrl: outputUrl,
                durationMs: totalDurationMs,
                isLosslessCopy: true,
                errorMessage: nil
            )
        }

        if ReturnCode.isCancel(returnCode) || isCancelled {
            return StitchResult(success: false, outputUrl: nil, durationMs: 0, isLosslessCopy: true, errorMessage: "Operation cancelled")
        }

        let errorLog = session?.getAllLogsAsString() ?? "Lossless stream copy failed"
        let lastLines = errorLog.components(separatedBy: .newlines).suffix(15).joined(separator: "\n")
        return StitchResult(success: false, outputUrl: nil, durationMs: 0, isLosslessCopy: true, errorMessage: "Lossless concat error:\n\(lastLines)")
    }

    // MARK: - Smart Match Concat (Hardware VideoToolbox)
    private func runSmartMatchConcat(
        clips: [StitchClipItem],
        outputUrl: URL,
        totalDurationSec: Double,
        totalDurationMs: Int64,
        onProgress: @escaping (Float, String) -> Void
    ) async -> StitchResult {
        let targetW = clips[0].width > 0 ? clips[0].width : 1920
        let targetH = clips[0].height > 0 ? clips[0].height : 1080
        let targetFps = clips[0].fps > 0 ? clips[0].fps : 30.0

        var inputsStr = ""
        var filterStr = ""

        for (i, clip) in clips.enumerated() {
            inputsStr += " -i \"\(clip.url.path)\""
            // Scale and pad to match master resolution, fix fps and sar
            filterStr += "[\(i):v]scale=\(targetW):\(targetH):force_original_aspect_ratio=decrease,pad=\(targetW):\(targetH):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(Int(targetFps))[v\(i)];"
        }

        // Concat filter graph
        for i in 0..<clips.count {
            filterStr += "[v\(i)][\(i):a?]"
        }
        filterStr += "concat=n=\(clips.count):v=1:a=1[outv][outa]"

        let cmd = "\(inputsStr) -filter_complex \"\(filterStr)\" -map \"[outv]\" -map \"[outa]\" -c:v h264_videotoolbox -b:v 14M -c:a aac -b:a 256k -movflags +faststart -y \"\(outputUrl.path)\""

        FFmpegKitConfig.enableStatisticsCallback { stats in
            guard let stats = stats, totalDurationSec > 0 else { return }
            let timeSec = Double(stats.getTime()) / 1000.0
            let frac = Float(min(0.99, max(0.02, timeSec / totalDurationSec)))
            let speed = stats.getSpeed()
            let speedStr = speed > 0 ? String(format: " (%.1fx)", speed) : ""
            DispatchQueue.main.async {
                onProgress(frac, "Smart Normalizing \(Int(frac * 100))%\(speedStr)...")
            }
        }

        let session = FFmpegKit.execute(cmd)
        let returnCode = session?.getReturnCode()

        FFmpegKitConfig.enableStatisticsCallback(nil)

        if ReturnCode.isSuccess(returnCode) && FileManager.default.fileExists(atPath: outputUrl.path) {
            onProgress(1.0, "Stitch completed!")
            return StitchResult(
                success: true,
                outputUrl: outputUrl,
                durationMs: totalDurationMs,
                isLosslessCopy: false,
                errorMessage: nil
            )
        }

        if ReturnCode.isCancel(returnCode) || isCancelled {
            return StitchResult(success: false, outputUrl: nil, durationMs: 0, isLosslessCopy: false, errorMessage: "Operation cancelled")
        }

        let errorLog = session?.getAllLogsAsString() ?? "Smart Match failed"
        let lastLines = errorLog.components(separatedBy: .newlines).suffix(15).joined(separator: "\n")
        return StitchResult(success: false, outputUrl: nil, durationMs: 0, isLosslessCopy: false, errorMessage: "Smart Stitch error:\n\(lastLines)")
    }

    /// Saves a video file to the user's Photos library
    func exportToPhotos(fileUrl: URL) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    continuation.resume(throwing: NSError(
                        domain: "CFXVideoStitch",
                        code: 403,
                        userInfo: [NSLocalizedDescriptionKey: "Photo Library access not granted"]
                    ))
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileUrl)
                }) { success, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: success)
                    }
                }
            }
        }
    }

    // MARK: - Helpers
    private func generateThumbnail(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let cgImg = try? gen.copyCGImage(at: time, actualTime: nil) {
            return UIImage(cgImage: cgImg)
        }
        return nil
    }

    private func normalizedCodec(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("avc") || lower.contains("h264") || lower.contains("264") { return "h264" }
        if lower.contains("hevc") || lower.contains("hvc1") || lower.contains("hev1") || lower.contains("265") { return "hevc" }
        if lower.contains("prores") { return "prores" }
        return lower
    }
}
