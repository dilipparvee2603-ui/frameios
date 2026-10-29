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
        var filterComplexParts: [String] = []
        var concatStreams = ""

        for (idx, clipUrl) in preparedClipUrls.enumerated() {
            concatArgs += ["-i", clipUrl.path]
            let clip = project.clips[idx]

            // Check if audio track exists on this clip
            let clipAsset = AVURLAsset(url: clipUrl)
            let audioTracks = (try? await clipAsset.loadTracks(withMediaType: .audio)) ?? []
            let hasAudioTrack = !audioTracks.isEmpty

            // 1. Video Filters
            var vFilters: [String] = []

            // A. Rotation & Flip
            if clip.hasKeyframes() {
                let rotPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.rotationDegrees) }
                let hasRotationAnim = rotPoints.contains { abs($0.value) > 0.01 }
                if hasRotationAnim {
                    let rotExpr = buildFFmpegTimeExpression(points: rotPoints, defaultValue: Double(clip.transform.rotation.rawValue))
                    vFilters.append("rotate='(\(rotExpr))*PI/180':ow='rotw((\(rotExpr))*PI/180)':oh='roth((\(rotExpr))*PI/180)':c=black")
                } else {
                    switch clip.transform.rotation {
                    case .r90: vFilters.append("transpose=1")
                    case .r180: vFilters.append("transpose=1,transpose=1")
                    case .r270: vFilters.append("transpose=2")
                    case .r0: break
                    }
                }
            } else {
                switch clip.transform.rotation {
                case .r90: vFilters.append("transpose=1")
                case .r180: vFilters.append("transpose=1,transpose=1")
                case .r270: vFilters.append("transpose=2")
                case .r0: break
                }
            }

            if clip.transform.flipH {
                vFilters.append("hflip")
            }
            if clip.transform.flipV {
                vFilters.append("vflip")
            }

            // B. Color grading
            if clip.color.contrast != 1.0 || clip.color.brightness != 0.0 || clip.color.saturation != 1.0 {
                vFilters.append("eq=contrast=\(String(format: "%.2f", clip.color.contrast)):brightness=\(String(format: "%.2f", clip.color.brightness)):saturation=\(String(format: "%.2f", clip.color.saturation))")
            }

            // Opacity keyframe support
            if clip.hasKeyframes() {
                let opPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.opacity) }
                let alphaExpr = buildFFmpegTimeExpression(points: opPoints, defaultValue: 1.0)
                vFilters.append("format=yuva420p,colorchannelmixer=aa='\(alphaExpr)'")
            } else if clip.transform.opacity < 0.999 {
                vFilters.append("format=yuva420p,colorchannelmixer=aa=\(String(format: "%.3f", clip.transform.opacity))")
            }

            // C. Conform & Scale with Zoom and Pan Offset onto canvas using overlay on black background
            let zoom = max(0.2, min(4.0, clip.transform.scale))
            // Scale offset from preview coordinate system (~200pt wide) to export target resolution
            let scaleMultiplier = Double(targetW) / 200.0

            let xOffsetExpr: String
            let yOffsetExpr: String

            if clip.hasKeyframes() {
                let xPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.positionX) }
                let yPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.positionY) }
                xOffsetExpr = buildFFmpegTimeExpression(points: xPoints, defaultValue: clip.transform.offsetX, multiplier: scaleMultiplier)
                yOffsetExpr = buildFFmpegTimeExpression(points: yPoints, defaultValue: clip.transform.offsetY, multiplier: scaleMultiplier)
            } else {
                let padX = Int(round(clip.transform.offsetX * scaleMultiplier))
                let padY = Int(round(clip.transform.offsetY * scaleMultiplier))
                xOffsetExpr = "\(padX)"
                yOffsetExpr = "\(padY)"
            }

            let clipDurationSec = max(0.1, Double(clip.timelineDurationMs) / 1000.0)

            vFilters.append("scale=\(targetW):\(targetH):force_original_aspect_ratio=decrease")
            if clip.hasKeyframes() {
                let scalePoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.scale) }
                let zoomExpr = buildFFmpegTimeExpression(points: scalePoints, defaultValue: clip.transform.scale)
                vFilters.append("scale=eval=frame:w='trunc(iw*(\(zoomExpr))/2)*2':h='trunc(ih*(\(zoomExpr))/2)*2'")
            } else {
                vFilters.append("scale=w='trunc(iw*\(String(format: "%.2f", zoom))/2)*2':h='trunc(ih*\(String(format: "%.2f", zoom))/2)*2'")
            }
            let vFilterStr = vFilters.joined(separator: ",")

            let xExpr = "(W-w)/2+(\(xOffsetExpr))"
            let yExpr = "(H-h)/2+(\(yOffsetExpr))"

            let durFormatted = String(format: "%.3f", clipDurationSec)

            filterComplexParts.append("color=c=black:s=\(targetW)x\(targetH):d=\(durFormatted):r=\(config.targetFps)[bg\(idx)]")
            filterComplexParts.append("[\(idx):v]\(vFilterStr)[fg\(idx)]")
            filterComplexParts.append("[bg\(idx)][fg\(idx)]overlay=x='\(xExpr)':y='\(yExpr)':shortest=1,setsar=1,fps=\(config.targetFps),trim=duration=\(durFormatted),setpts=PTS-STARTPTS[v\(idx)]")

            // 2. Audio Filters
            if hasAudioTrack && !clip.isMuted {
                let vol = String(format: "%.2f", clip.volume)
                filterComplexParts.append("[\(idx):a]volume=\(vol),aformat=sample_rates=48000:channel_layouts=stereo,atrim=duration=\(durFormatted),asetpts=PTS-STARTPTS[a\(idx)]")
            } else {
                // Generate silent audio of exact duration so multi-clip concat never fails
                filterComplexParts.append("aevalsrc=0:d=\(durFormatted):s=48000:c=stereo,atrim=duration=\(durFormatted),asetpts=PTS-STARTPTS[a\(idx)]")
            }

            concatStreams += "[v\(idx)][a\(idx)]"
        }

        let concatFilter = "\(concatStreams)concat=n=\(preparedClipUrls.count):v=1:a=1[outv][outa]"
        filterComplexParts.append(concatFilter)

        let filterComplexString = filterComplexParts.joined(separator: ";")

        concatArgs += [
            "-filter_complex", filterComplexString,
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

    /// Evaluates piecewise linear keyframe interpolation expression over time `t` (seconds) for FFmpeg filtergraphs
    private func buildFFmpegTimeExpression(
        points: [(timeMs: Int64, value: Double)],
        defaultValue: Double,
        multiplier: Double = 1.0
    ) -> String {
        let sorted = points.sorted { $0.timeMs < $1.timeMs }
        guard !sorted.isEmpty else {
            return String(format: "%.2f", defaultValue * multiplier)
        }
        if sorted.count == 1 {
            let v = sorted[0].value * multiplier
            return String(format: "%.2f", v)
        }

        var expr = String(format: "%.2f", sorted.last!.value * multiplier)
        for i in stride(from: sorted.count - 2, through: 0, by: -1) {
            let k0 = sorted[i]
            let k1 = sorted[i + 1]
            let t0 = Double(k0.timeMs) / 1000.0
            let t1 = Double(k1.timeMs) / 1000.0
            let v0 = k0.value * multiplier
            let v1 = k1.value * multiplier
            let span = max(0.001, t1 - t0)
            let segExpr = "\(String(format: "%.2f", v0))+(\(String(format: "%.2f", v1 - v0)))*(t-\(String(format: "%.3f", t0)))/\(String(format: "%.3f", span))"
            expr = "if(lt(t,\(String(format: "%.3f", t1))),\(segExpr),\(expr))"
        }
        let firstT = Double(sorted.first!.timeMs) / 1000.0
        let firstV = sorted.first!.value * multiplier
        expr = "if(lt(t,\(String(format: "%.3f", firstT))),\(String(format: "%.2f", firstV)),\(expr))"
        return expr
    }
}
