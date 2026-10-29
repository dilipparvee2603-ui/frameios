import Foundation
import AVFoundation
import Photos
import ffmpegkit
import UIKit

// MARK: - Export Configuration
struct ProjectExportConfig {
    var resolution: AspectRatioPreset = .ratio9x16
    var customWidth: Int = 1080
    var customHeight: Int = 1920
    var targetFps: Int = 30
    var videoCodec: String = "h264_videotoolbox" // or hevc_videotoolbox
    var bitrateMbps: Double = 18.0
    var saveToCameraRoll: Bool = true
}

// MARK: - Export Result
struct EditorExportResult {
    let success: Bool
    let outputUrl: URL?
    let errorMessage: String?
}

// MARK: - Master Video Editor Export Engine
final class VideoEditorExportEngine {
    static let shared = VideoEditorExportEngine()

    private var isCancelled: Bool = false

    private init() {}

    func cancel() {
        isCancelled = true
        FFmpegKit.cancel()
    }

    /// Renders an entire VideoProject with all clips, trims, slow-mo speeds, optical-flow interpolation, transforms, color grading, and audio tracks
    func exportProject(
        project: VideoProject,
        config: ProjectExportConfig,
        onProgress: @escaping (Double, String) -> Void
    ) async -> EditorExportResult {
        isCancelled = false
        guard !project.clips.isEmpty else {
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Project contains no video clips.")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let outputUrl = tempDir.appendingPathComponent("CFX_Render_\(timestamp).mp4")
        try? FileManager.default.removeItem(at: outputUrl)

        onProgress(0.05, "Preparing media clips & timeline...")

        // Step 1: Process individual clips (apply slow-mo / optical flow if speed is retimed)
        var preparedClipUrls: [URL] = []
        let totalClips = project.clips.count

        for (idx, clip) in project.clips.enumerated() {
            if isCancelled {
                return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Export cancelled")
            }

            let clipProgressBase = 0.05 + (Double(idx) / Double(totalClips)) * 0.65
            let clipProgressSpan = (1.0 / Double(totalClips)) * 0.65

            let renderedClipUrl: URL
            let hasSpeedRetime = abs(clip.speedConfig.speedMultiplier - 1.0) > 0.01 || clip.speedConfig.isRamp

            if hasSpeedRetime {
                onProgress(clipProgressBase, "Rendering Slow-Mo (Clip \(idx + 1)/\(totalClips))...")
                let slowMoResult = await SlowMoEngine.shared.createSlowMotion(
                    sourceUrl: clip.sourceUrl,
                    speedPercentage: clip.speedConfig.speedMultiplier * 100.0,
                    targetFps: config.targetFps,
                    interpolationMode: clip.speedConfig.interpolationMode,
                    audioMode: clip.speedConfig.audioMode,
                    inPointMs: clip.sourceInPointMs,
                    outPointMs: clip.sourceOutPointMs,
                    totalSourceDurationMs: clip.sourceDurationMs,
                    onProgress: { fraction, speedText in
                        let overallFraction = clipProgressBase + (fraction * clipProgressSpan)
                        onProgress(overallFraction, "Optical Flow Retiming (Clip \(idx + 1)/\(totalClips)) \(speedText)")
                    }
                )

                guard slowMoResult.success, let resUrl = slowMoResult.outputUrl else {
                    return EditorExportResult(
                        success: false,
                        outputUrl: nil,
                        errorMessage: "Failed to render Clip \(idx + 1): \(slowMoResult.errorMessage ?? "Unknown engine error")"
                    )
                }
                renderedClipUrl = resUrl
            } else {
                // Just extract trimmed portion
                onProgress(clipProgressBase, "Trimming (Clip \(idx + 1)/\(totalClips))...")
                let trimResult = await VideoTrimEngine.shared.trimVideo(
                    srcUrl: clip.sourceUrl,
                    startMs: clip.sourceInPointMs,
                    endMs: clip.sourceOutPointMs,
                    includeAudio: !clip.isMuted,
                    mode: .frameAccurate,
                    onProgress: { p in
                        let overallFraction = clipProgressBase + (Double(p) * clipProgressSpan)
                        onProgress(overallFraction, "Preparing Clip \(idx + 1)/\(totalClips)...")
                    }
                )

                guard trimResult.success, let resUrl = trimResult.outputUrl else {
                    return EditorExportResult(
                        success: false,
                        outputUrl: nil,
                        errorMessage: "Failed to trim Clip \(idx + 1): \(trimResult.errorMessage ?? "Trim error")"
                    )
                }
                renderedClipUrl = resUrl
            }

            preparedClipUrls.append(renderedClipUrl)
        }

        if isCancelled {
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Export cancelled")
        }

        onProgress(0.75, "Compositing clips & color grading...")

        // Step 2: Composite & Normalize all clips into target canvas dimensions
        let canvasDims = config.resolution.renderDimensions(baseWidth: CGFloat(config.customWidth))
        let targetW = Int(canvasDims.width)
        let targetH = Int(canvasDims.height)

        var concatArgs: [String] = ["-threads", "0", "-y"]
        var filterComplexInputs = ""
        var filterComplexStreams = ""

        for (idx, clipUrl) in preparedClipUrls.enumerated() {
            concatArgs += ["-i", clipUrl.path]
            let clip = project.clips[idx]

            // Color grading filters
            var colorFilters: [String] = []
            if clip.color.contrast != 1.0 { colorFilters.append("eq=contrast=\(String(format: "%.2f", clip.color.contrast))") }
            if clip.color.brightness != 0.0 { colorFilters.append("eq=brightness=\(String(format: "%.2f", clip.color.brightness))") }
            if clip.color.saturation != 1.0 { colorFilters.append("eq=saturation=\(String(format: "%.2f", clip.color.saturation))") }

            let colorStr = colorFilters.isEmpty ? "" : (colorFilters.joined(separator: ",") + ",")

            // Scale & Pad to target canvas aspect
            let scaleFilter = "\(colorStr)scale=\(targetW):\(targetH):force_original_aspect_ratio=decrease,pad=\(targetW):\(targetH):(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=\(config.targetFps)"
            filterComplexInputs += "[\(idx):v]\(scaleFilter)[v\(idx)];"
            filterComplexStreams += "[v\(idx)][\(idx):a]"
        }

        let concatStream = "\(filterComplexInputs)\(filterComplexStreams)concat=n=\(preparedClipUrls.count):v=1:a=1[outv][outa]"

        concatArgs += [
            "-filter_complex", concatStream,
            "-map", "[outv]",
            "-map", "[outa]",
            "-c:v", config.videoCodec,
            "-b:v", "\(Int(config.bitrateMbps))M",
            "-maxrate", "\(Int(config.bitrateMbps * 1.3))M",
            "-profile:v", "high",
            "-allow_sw", "1",
            "-pix_fmt", "yuv420p",
            "-colorspace", "1",
            "-color_primaries", "1",
            "-color_trc", "1",
            "-c:a", "aac",
            "-b:a", "320k",
            "-movflags", "+faststart",
            outputUrl.path
        ]

        onProgress(0.85, "Encoding master video with VideoToolbox...")

        let session = FFmpegKit.execute(withArguments: concatArgs)
        let code = session?.getReturnCode()

        // Clean up intermediate clip renders
        for clipUrl in preparedClipUrls {
            try? FileManager.default.removeItem(at: clipUrl)
        }

        if isCancelled || ReturnCode.isCancel(code) {
            try? FileManager.default.removeItem(at: outputUrl)
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Export cancelled")
        }

        if ReturnCode.isSuccess(code), FileManager.default.fileExists(atPath: outputUrl.path) {
            onProgress(0.95, "Saving to Camera Roll...")
            if config.saveToCameraRoll {
                _ = try? await DirectDownloadEngine().saveVideoToPhotos(url: outputUrl)
            }
            onProgress(1.0, "Complete!")
            return EditorExportResult(success: true, outputUrl: outputUrl, errorMessage: nil)
        } else {
            let logs = session?.getAllLogsAsString() ?? "Composition encoding failed"
            let err = logs.split(separator: "\n").suffix(5).joined(separator: "\n")
            try? FileManager.default.removeItem(at: outputUrl)
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Render failure:\n\(err)")
        }
    }
}
