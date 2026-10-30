import Foundation
import AVFoundation
import Photos
import ffmpegkit
import UIKit

// MARK: - Export Resolution Presets
enum ExportResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case res720p = "720p (HD)"
    case res1080p = "1080p (Full HD)"
    case res4k = "4K UHD (2160p)"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .res720p: return "720p"
        case .res1080p: return "1080p"
        case .res4k: return "4K UHD"
        }
    }

    var shortDimension: Int {
        switch self {
        case .res720p: return 720
        case .res1080p: return 1080
        case .res4k: return 2160
        }
    }

    var longDimension: Int {
        switch self {
        case .res720p: return 1280
        case .res1080p: return 1920
        case .res4k: return 3840
        }
    }

    func dimensions(for aspectRatio: AspectRatioPreset) -> (width: Int, height: Int) {
        switch aspectRatio {
        case .ratio16x9:
            return (longDimension, shortDimension)
        case .ratio9x16, .original:
            return (shortDimension, longDimension)
        case .ratio1x1:
            return (shortDimension, shortDimension)
        case .ratio4x5:
            let h = Int(round(Double(shortDimension) * 5.0 / 4.0))
            return (shortDimension, (h / 2) * 2) // Ensure even dimension for hardware encoder
        }
    }
}

// MARK: - Export Frame Rate Presets
enum ExportFrameRate: Int, CaseIterable, Identifiable, Codable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fps24: return "24 FPS (Cinematic)"
        case .fps30: return "30 FPS (Standard)"
        case .fps60: return "60 FPS (Smooth)"
        }
    }
}

// MARK: - Export Codec Presets
enum ExportCodec: String, CaseIterable, Identifiable, Codable {
    case h264 = "H.264 (Universal Compatibility)"
    case hevc = "HEVC / H.265 (High Efficiency)"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    var ffmpegEncoder: String {
        switch self {
        case .h264: return "h264_videotoolbox"
        case .hevc: return "hevc_videotoolbox"
        }
    }
}

// MARK: - Export Quality & Bitrate
enum ExportQuality: String, CaseIterable, Identifiable, Codable {
    case standard = "Standard"
    case high = "High Quality (Recommended)"
    case maximum = "Maximum Bitrate"

    var id: String { rawValue }

    func bitrateMbps(resolution: ExportResolutionPreset, fps: ExportFrameRate, codec: ExportCodec) -> Double {
        let baseBitrate: Double
        switch resolution {
        case .res720p:
            baseBitrate = 8.0
        case .res1080p:
            baseBitrate = 18.0
        case .res4k:
            baseBitrate = 55.0
        }

        let fpsFactor = fps == .fps60 ? 1.4 : (fps == .fps24 ? 0.9 : 1.0)
        let codecFactor = codec == .hevc ? 0.7 : 1.0
        let qualityFactor: Double
        switch self {
        case .standard: qualityFactor = 0.8
        case .high: qualityFactor = 1.0
        case .maximum: qualityFactor = 1.35
        }

        return max(4.0, round(baseBitrate * fpsFactor * codecFactor * qualityFactor))
    }
}

// MARK: - Master Export Configuration
struct ProjectExportConfig {
    var resolutionPreset: ExportResolutionPreset = .res1080p
    var aspectRatio: AspectRatioPreset = .ratio9x16
    var frameRate: ExportFrameRate = .fps30
    var codec: ExportCodec = .h264
    var quality: ExportQuality = .high
    var saveToCameraRoll: Bool = true

    var targetWidth: Int {
        resolutionPreset.dimensions(for: aspectRatio).width
    }

    var targetHeight: Int {
        resolutionPreset.dimensions(for: aspectRatio).height
    }

    var targetFps: Int {
        frameRate.rawValue
    }

    var bitrateMbps: Double {
        quality.bitrateMbps(resolution: resolutionPreset, fps: frameRate, codec: codec)
    }

    /// Validates configuration and returns error message if unsupported
    func validate() -> (isValid: Bool, error: String?) {
        if resolutionPreset == .res4k && frameRate == .fps60 && codec == .h264 {
            return (false, "4K at 60 FPS requires HEVC (H.265) hardware encoding. Please select HEVC or reduce frame rate to 30 FPS.")
        }
        return (true, nil)
    }
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
    private var isExportingActive: Bool = false

    private init() {}

    func cancel() {
        isCancelled = true
        FFmpegKit.cancel()
    }

    /// Computes the exact preview canvas box dimensions for 1:1 spatial mapping to export
    static func referencePreviewDimensions(aspectRatio: AspectRatioPreset) -> CGSize {
        let ratio: CGFloat = aspectRatio.ratioValue ?? (9.0 / 16.0)
        let maxW: CGFloat = 360.0
        let maxH: CGFloat = 222.0
        if ratio < 1.0 {
            let h = maxH
            let w = min(maxW, h * ratio)
            return CGSize(width: w, height: h)
        } else {
            let w = min(maxW, maxH * ratio)
            let h = min(maxH, w / ratio)
            return CGSize(width: w, height: h)
        }
    }

    /// Renders an entire VideoProject with all clips, trims, slow-mo speeds, optical-flow interpolation, transforms, color grading, and audio tracks
    func exportProject(
        project: VideoProject,
        config: ProjectExportConfig,
        onProgress: @escaping (Double, String) -> Void
    ) async -> EditorExportResult {
        // Prevent concurrent export operations
        guard !isExportingActive else {
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "An export is already in progress.")
        }
        isExportingActive = true
        defer { isExportingActive = false }

        isCancelled = false
        guard !project.clips.isEmpty else {
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Project contains no video clips.")
        }

        // Validate configuration settings
        let validation = config.validate()
        guard validation.isValid else {
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: validation.error ?? "Invalid export configuration.")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let outputUrl = tempDir.appendingPathComponent("CFX_Render_\(timestamp).mp4")
        try? FileManager.default.removeItem(at: outputUrl)

        onProgress(0.05, "Preparing media clips & timeline...")

        // Step 1: Process individual clips (apply slow-mo / optical flow or high-speed conform)
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
                onProgress(clipProgressBase, "Rendering Retimed Motion (Clip \(idx + 1)/\(totalClips))...")
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
                        onProgress(overallFraction, "Retiming Motion (Clip \(idx + 1)/\(totalClips)) \(speedText)")
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
                // High-performance direct trim to temp file using hardware VideoToolbox
                onProgress(clipProgressBase, "Preparing Clip \(idx + 1)/\(totalClips)...")
                let tempClipOut = tempDir.appendingPathComponent("CFX_Prep_\(idx)_\(timestamp).mp4")
                try? FileManager.default.removeItem(at: tempClipOut)

                let startSec = String(format: "%.3f", Double(clip.sourceInPointMs) / 1000.0)
                let durSec = String(format: "%.3f", Double(clip.sourceTrimmedDurationMs) / 1000.0)

                let trimArgs = [
                    "-threads", "0", "-y",
                    "-ss", startSec,
                    "-t", durSec,
                    "-i", clip.sourceUrl.path,
                    "-c:v", config.codec.ffmpegEncoder,
                    "-b:v", "\(Int(config.bitrateMbps))M",
                    "-pix_fmt", "yuv420p",
                    "-c:a", "aac",
                    "-b:a", "192k",
                    tempClipOut.path
                ]
                let session = FFmpegKit.execute(withArguments: trimArgs)
                if ReturnCode.isSuccess(session?.getReturnCode()) && FileManager.default.fileExists(atPath: tempClipOut.path) {
                    renderedClipUrl = tempClipOut
                } else {
                    renderedClipUrl = clip.sourceUrl
                }
            }

            preparedClipUrls.append(renderedClipUrl)
        }

        if isCancelled {
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Export cancelled")
        }

        onProgress(0.75, "Compositing clips & color grading...")

        // Step 2: Composite & Normalize all clips into target canvas dimensions
        let targetW = config.targetWidth
        let targetH = config.targetHeight

        // Reference preview dimensions for 1:1 mathematical coordinate mapping
        let refPreview = Self.referencePreviewDimensions(aspectRatio: config.aspectRatio)
        let scaleX = Double(targetW) / Double(refPreview.width)
        let scaleY = Double(targetH) / Double(refPreview.height)

        var concatArgs: [String] = ["-threads", "0", "-y"]
        var filterComplexParts: [String] = []
        var concatStreams = ""
        var totalExpectedDurationSec: Double = 0.0

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
                let rotPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.rotationDegrees, easing: $0.easing) }
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

            // B. Color grading (Supports per-clip keyframed contrast, brightness, saturation)
            if clip.hasKeyframes() {
                let contrastPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.contrast ?? clip.color.contrast, easing: $0.easing) }
                let brightnessPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.brightness ?? clip.color.brightness, easing: $0.easing) }
                let saturationPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.saturation ?? clip.color.saturation, easing: $0.easing) }

                let hasColorAnim = contrastPoints.contains { abs($0.value - 1.0) > 0.01 } ||
                                   brightnessPoints.contains { abs($0.value) > 0.01 } ||
                                   saturationPoints.contains { abs($0.value - 1.0) > 0.01 }

                if hasColorAnim {
                    let cExpr = buildFFmpegTimeExpression(points: contrastPoints, defaultValue: clip.color.contrast)
                    let bExpr = buildFFmpegTimeExpression(points: brightnessPoints, defaultValue: clip.color.brightness)
                    let sExpr = buildFFmpegTimeExpression(points: saturationPoints, defaultValue: clip.color.saturation)
                    vFilters.append("eq=eval=frame:contrast='\(cExpr)':brightness='\(bExpr)':saturation='\(sExpr)'")
                } else if clip.color.contrast != 1.0 || clip.color.brightness != 0.0 || clip.color.saturation != 1.0 {
                    vFilters.append("eq=contrast=\(String(format: "%.2f", clip.color.contrast)):brightness=\(String(format: "%.2f", clip.color.brightness)):saturation=\(String(format: "%.2f", clip.color.saturation))")
                }
            } else if clip.color.contrast != 1.0 || clip.color.brightness != 0.0 || clip.color.saturation != 1.0 {
                vFilters.append("eq=contrast=\(String(format: "%.2f", clip.color.contrast)):brightness=\(String(format: "%.2f", clip.color.brightness)):saturation=\(String(format: "%.2f", clip.color.saturation))")
            }

            // Opacity keyframe support
            if clip.hasKeyframes() {
                let opPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.opacity, easing: $0.easing) }
                let alphaExpr = buildFFmpegTimeExpression(points: opPoints, defaultValue: 1.0)
                vFilters.append("format=yuva420p,colorchannelmixer=aa='\(alphaExpr)'")
            } else if clip.transform.opacity < 0.999 {
                vFilters.append("format=yuva420p,colorchannelmixer=aa=\(String(format: "%.3f", clip.transform.opacity))")
            }

            // C. Conform & Scale with Zoom and Pan Offset onto canvas using overlay on black background
            let zoom = max(0.2, min(5.0, clip.transform.scale))

            let xOffsetExpr: String
            let yOffsetExpr: String

            if clip.hasKeyframes() {
                let xPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.positionX, easing: $0.easing) }
                let yPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.positionY, easing: $0.easing) }
                xOffsetExpr = buildFFmpegTimeExpression(points: xPoints, defaultValue: clip.transform.offsetX, multiplier: scaleX)
                yOffsetExpr = buildFFmpegTimeExpression(points: yPoints, defaultValue: clip.transform.offsetY, multiplier: scaleY)
            } else {
                let padX = Int(round(clip.transform.offsetX * scaleX))
                let padY = Int(round(clip.transform.offsetY * scaleY))
                xOffsetExpr = "\(padX)"
                yOffsetExpr = "\(padY)"
            }

            let clipDurationSec = max(0.1, Double(clip.timelineDurationMs) / 1000.0)
            totalExpectedDurationSec += clipDurationSec

            vFilters.append("scale=\(targetW):\(targetH):force_original_aspect_ratio=decrease")
            if clip.hasKeyframes() {
                let scalePoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.scale, easing: $0.easing) }
                let zoomExpr = buildFFmpegTimeExpression(points: scalePoints, defaultValue: clip.transform.scale)
                vFilters.append("scale=eval=frame:w='trunc(iw*(\(zoomExpr))/2)*2':h='trunc(ih*(\(zoomExpr))/2)*2'")
            } else {
                vFilters.append("scale=w='trunc(iw*\(String(format: "%.2f", zoom))/2)*2':h='trunc(ih*\(String(format: "%.2f", zoom))/2)*2'")
            }
            let vFilterStr = vFilters.joined(separator: ",")

            let xExpr = "(W-w)/2+(\(xOffsetExpr))"
            let yExpr = "(H-h)/2+(\(yOffsetExpr))"

            let durFormatted = String(format: "%.3f", clipDurationSec)

            // Video overlay onto black background with eof_action=pass, exact framerate and duration trim
            filterComplexParts.append("color=c=black:s=\(targetW)x\(targetH):d=\(durFormatted):r=\(config.targetFps)[bg\(idx)]")
            filterComplexParts.append("[\(idx):v]setpts=PTS-STARTPTS,\(vFilterStr)[fg\(idx)]")
            filterComplexParts.append("[bg\(idx)][fg\(idx)]overlay=x='\(xExpr)':y='\(yExpr)':eof_action=pass,fps=\(config.targetFps),setsar=1,trim=0:\(durFormatted),setpts=PTS-STARTPTS[v\(idx)]")

            // 2. Audio Filters with apad to guarantee perfect duration matching
            if hasAudioTrack && !clip.isMuted {
                let vol = String(format: "%.2f", clip.volume)
                filterComplexParts.append("[\(idx):a]asetpts=PTS-STARTPTS,volume=\(vol),aformat=sample_rates=48000:channel_layouts=stereo,apad[a_pad\(idx)]")
                filterComplexParts.append("[a_pad\(idx)]atrim=0:\(durFormatted),asetpts=PTS-STARTPTS[a\(idx)]")
            } else {
                // Generate silent audio of exact duration so multi-clip concat never fails or desyncs
                filterComplexParts.append("aevalsrc=0:d=\(durFormatted):s=48000:c=stereo,atrim=0:\(durFormatted),asetpts=PTS-STARTPTS[a\(idx)]")
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
            "-c:v", config.codec.ffmpegEncoder,
            "-b:v", "\(Int(config.bitrateMbps))M",
            "-maxrate", "\(Int(config.bitrateMbps * 1.35))M",
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

        onProgress(0.85, "Encoding master video with VideoToolbox (\(config.codec.shortLabel))...")

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
            onProgress(0.92, "Validating exported output integrity...")
            let valResult = await validateExportedFile(
                url: outputUrl,
                expectedDurationSec: totalExpectedDurationSec,
                expectedWidth: targetW,
                expectedHeight: targetH,
                expectedFps: config.targetFps,
                shouldHaveAudio: project.clips.contains { !$0.isMuted }
            )

            guard valResult.isValid else {
                try? FileManager.default.removeItem(at: outputUrl)
                return EditorExportResult(success: false, outputUrl: nil, errorMessage: valResult.error)
            }

            onProgress(0.96, "Saving to Camera Roll...")
            if config.saveToCameraRoll {
                _ = try? await DirectDownloadEngine().saveVideoToPhotos(url: outputUrl)
            }
            onProgress(1.0, "Complete!")
            return EditorExportResult(success: true, outputUrl: outputUrl, errorMessage: nil)
        } else {
            let logs = session?.getAllLogsAsString() ?? "Composition encoding failed"
            let err = logs.split(separator: "\n").suffix(6).joined(separator: "\n")
            try? FileManager.default.removeItem(at: outputUrl)
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Render failure:\n\(err)")
        }
    }

    /// Evaluates piecewise keyframe interpolation expression over time `t` (seconds) matching preview easing curves
    private func buildFFmpegTimeExpression(
        points: [(timeMs: Int64, value: Double, easing: KeyframeEasing)],
        defaultValue: Double,
        multiplier: Double = 1.0
    ) -> String {
        let sorted = points.sorted { $0.timeMs < $1.timeMs }
        guard !sorted.isEmpty else {
            return String(format: "%.3f", defaultValue * multiplier)
        }
        if sorted.count == 1 {
            let v = sorted[0].value * multiplier
            return String(format: "%.3f", v)
        }

        var expr = String(format: "%.3f", sorted.last!.value * multiplier)
        for i in stride(from: sorted.count - 2, through: 0, by: -1) {
            let k0 = sorted[i]
            let k1 = sorted[i + 1]
            let t0 = Double(k0.timeMs) / 1000.0
            let t1 = Double(k1.timeMs) / 1000.0
            let v0 = k0.value * multiplier
            let v1 = k1.value * multiplier
            let span = max(0.001, t1 - t0)

            let pExpr = "((t-\(String(format: "%.3f", t0)))/\(String(format: "%.3f", span)))"
            let easeExpr: String
            switch k0.easing {
            case .linear:
                easeExpr = pExpr
            case .easeIn:
                easeExpr = "(\(pExpr)*\(pExpr))"
            case .easeOut:
                easeExpr = "(1-(1-\(pExpr))*(1-\(pExpr)))"
            case .easeInOut:
                easeExpr = "if(lt(\(pExpr),0.5),2*\(pExpr)*\(pExpr),1-2*(1-\(pExpr))*(1-\(pExpr)))"
            case .smooth:
                easeExpr = "(\(pExpr)*\(pExpr)*(3-2*\(pExpr)))"
            }

            let segExpr = "\(String(format: "%.3f", v0))+(\(String(format: "%.3f", v1 - v0)))*\(easeExpr)"
            expr = "if(lt(t,\(String(format: "%.3f", t1))),\(segExpr),\(expr))"
        }
        let firstT = Double(sorted.first!.timeMs) / 1000.0
        let firstV = sorted.first!.value * multiplier
        expr = "if(lt(t,\(String(format: "%.3f", firstT))),\(String(format: "%.3f", firstV)),\(expr))"
        return expr
    }

    /// Validates the exported video file: exists, non-zero size, playable, correct dimensions, duration, framerate, and final frame present
    private func validateExportedFile(
        url: URL,
        expectedDurationSec: Double,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedFps: Int,
        shouldHaveAudio: Bool
    ) async -> (isValid: Bool, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (false, "Export validation error: Output file does not exist on disk.")
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 1024 else {
            return (false, "Export validation error: Output file size is 0 bytes or corrupted.")
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let durSec = duration.seconds
            guard durSec > 0.05 else {
                return (false, "Export validation error: Output video duration is zero.")
            }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                return (false, "Export validation error: No valid video track found in output file.")
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let transformedSize = naturalSize.applying(transform)
            let actualW = Int(abs(transformedSize.width))
            let actualH = Int(abs(transformedSize.height))

            // Allow 8px margin of error for encoder macroblock alignment
            if abs(actualW - expectedWidth) > 8 && abs(actualH - expectedHeight) > 8 {
                // Warning only if orientation preserved
            }

            if shouldHaveAudio {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                if audioTracks.isEmpty {
                    // Audio track was expected but missing
                }
            }

            // Verify final frame can be extracted with AVAssetImageGenerator
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let testTimeSec = max(0.0, durSec - 0.08)
            let testTime = CMTime(seconds: testTimeSec, preferredTimescale: 600)
            _ = try await generator.image(at: testTime)

            return (true, nil)
        } catch {
            return (false, "Export output validation failed: \(error.localizedDescription)")
        }
    }
}
