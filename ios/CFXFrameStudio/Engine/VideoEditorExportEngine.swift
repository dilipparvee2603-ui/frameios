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
enum EditorCodec: String, CaseIterable, Identifiable, Codable {
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

    func bitrateMbps(resolution: ExportResolutionPreset, fps: ExportFrameRate, codec: EditorCodec) -> Double {
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
    var codec: EditorCodec = .h264
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

    /// Renders an entire VideoProject with all clips, trims, slow-mo speeds, optical-flow interpolation, transforms, color grading, transitions, text overlays, and audio tracks
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
        isCancelled = false

        var temporaryFilesToDelete: [URL] = []

        defer {
            isExportingActive = false

            // Safe cleanup: ONLY delete generated temporary files; never delete original media
            for fileUrl in temporaryFilesToDelete {
                if !project.clips.contains(where: { $0.sourceUrl == fileUrl }) &&
                   !project.audioTracks.contains(where: { $0.url == fileUrl }) {
                    try? FileManager.default.removeItem(at: fileUrl)
                }
            }
        }

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

        // Step 1: Process individual clips (apply slow-mo / variable speed ramps or direct trims)
        var preparedClipUrls: [URL] = []
        let totalClips = project.clips.count

        for (idx, clip) in project.clips.enumerated() {
            if isCancelled {
                return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Export cancelled")
            }

            let clipProgressBase = 0.05 + (Double(idx) / Double(totalClips)) * 0.60
            let clipProgressSpan = (1.0 / Double(totalClips)) * 0.60

            let renderedClipUrl: URL
            let hasSpeedRetime = abs(clip.speedConfig.speedMultiplier - 1.0) > 0.01 || clip.speedConfig.isRamp

            if hasSpeedRetime {
                onProgress(clipProgressBase, "Rendering Retimed Motion (Clip \(idx + 1)/\(totalClips))...")
                let slowMoResult = await SlowMoEngine.shared.createSlowMotion(
                    sourceUrl: clip.sourceUrl,
                    speedConfig: clip.speedConfig,
                    targetFps: config.targetFps,
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
                        errorMessage: "Failed to render Clip \(idx + 1): \(slowMoResult.errorMessage ?? "Slow-motion engine error")"
                    )
                }
                temporaryFilesToDelete.append(resUrl)
                renderedClipUrl = resUrl
            } else {
                // High-performance direct trim to temp file using hardware VideoToolbox
                onProgress(clipProgressBase, "Preparing Clip \(idx + 1)/\(totalClips)...")
                let tempClipOut = tempDir.appendingPathComponent("CFX_Prep_\(idx)_\(timestamp).mp4")
                temporaryFilesToDelete.append(tempClipOut)
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
                    "-allow_sw", "1",
                    "-pix_fmt", "yuv420p",
                    "-c:a", "aac",
                    "-b:a", "192k",
                    tempClipOut.path
                ]
                let session = FFmpegKit.execute(withArguments: trimArgs)

                guard ReturnCode.isSuccess(session?.getReturnCode()) && FileManager.default.fileExists(atPath: tempClipOut.path) else {
                    return EditorExportResult(
                        success: false,
                        outputUrl: nil,
                        errorMessage: "Failed to prepare and trim Clip \(idx + 1). Original source media preserved."
                    )
                }
                renderedClipUrl = tempClipOut
            }

            preparedClipUrls.append(renderedClipUrl)
        }

        if isCancelled {
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Export cancelled")
        }

        onProgress(0.70, "Compositing clips, transforms & color grading...")

        // Step 2: Composite & Normalize all clips into target canvas dimensions
        let targetW = config.targetWidth
        let targetH = config.targetHeight

        // Reference preview dimensions for 1:1 mathematical coordinate mapping
        let refPreview = Self.referencePreviewDimensions(aspectRatio: config.aspectRatio)
        let scaleX = Double(targetW) / Double(refPreview.width)
        let scaleY = Double(targetH) / Double(refPreview.height)

        var concatArgs: [String] = ["-threads", "0", "-y"]
        var filterComplexParts: [String] = []
        var clipDurations: [Double] = []
        var totalExpectedDurationSec: Double = 0.0

        for (idx, clipUrl) in preparedClipUrls.enumerated() {
            concatArgs += ["-i", clipUrl.path]
            let clip = project.clips[idx]

            // Check if audio track exists on this clip
            let clipAsset = AVURLAsset(url: clipUrl)
            let hasAudioTrack = !clipAsset.tracks(withMediaType: .audio).isEmpty

            // 1. Video Filters
            var vFilters: [String] = []

            // A. Fit & Fill (Aspect Ratio conformation)
            switch clip.transform.fitMode {
            case .fit:
                vFilters.append("scale=\(targetW):\(targetH):force_original_aspect_ratio=decrease")
            case .fill:
                vFilters.append("scale=\(targetW):\(targetH):force_original_aspect_ratio=increase,crop=\(targetW):\(targetH)")
            }

            // B. Zoom / Scale
            if clip.hasKeyframes() {
                let scalePoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.scale, easing: $0.easing) }
                if scalePoints.contains(where: { abs($0.value - 1.0) > 0.01 }) {
                    let zoomExpr = buildFFmpegTimeExpression(points: scalePoints, defaultValue: clip.transform.scale)
                    vFilters.append("scale=eval=frame:w='trunc(iw*(\(zoomExpr))/2)*2':h='trunc(ih*(\(zoomExpr))/2)*2'")
                } else if abs(clip.transform.scale - 1.0) > 0.01 {
                    let z = max(0.2, min(5.0, clip.transform.scale))
                    vFilters.append("scale=w='trunc(iw*\(String(format: "%.4f", z))/2)*2':h='trunc(ih*\(String(format: "%.4f", z))/2)*2'")
                }
            } else if abs(clip.transform.scale - 1.0) > 0.01 {
                let z = max(0.2, min(5.0, clip.transform.scale))
                vFilters.append("scale=w='trunc(iw*\(String(format: "%.4f", z))/2)*2':h='trunc(ih*\(String(format: "%.4f", z))/2)*2'")
            }

            // C. Rotation (with uncropped expansion)
            let rotExpr: String?
            if clip.hasKeyframes() {
                let rotPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.rotationDegrees, easing: $0.easing) }
                if rotPoints.contains(where: { abs($0.value) > 0.01 }) {
                    rotExpr = buildFFmpegTimeExpression(points: rotPoints, defaultValue: Double(clip.transform.rotation.rawValue))
                } else if clip.transform.rotation != .r0 {
                    rotExpr = "\(clip.transform.rotation.rawValue)"
                } else {
                    rotExpr = nil
                }
            } else if clip.transform.rotation != .r0 {
                rotExpr = "\(clip.transform.rotation.rawValue)"
            } else {
                rotExpr = nil
            }

            if let rExpr = rotExpr {
                vFilters.append("rotate=a='(\(rExpr))*PI/180':ow='rotw((\(rExpr))*PI/180)':oh='roth((\(rExpr))*PI/180)':c=none")
            }

            // D. Flips
            if clip.transform.flipH {
                vFilters.append("hflip")
            }
            if clip.transform.flipV {
                vFilters.append("vflip")
            }

            // E. Color Grading (Exposure, Temperature, Tint, Brightness, Contrast, Saturation) & Opacity
            let expMultiplier = pow(2.0, clip.color.exposure)
            let baseContrast = clip.color.contrast * expMultiplier
            let baseBrightness = clip.color.brightness + (0.05 * clip.color.exposure)

            if clip.color.temperature != 6500.0 {
                let tempK = Int(round(max(2000.0, min(10000.0, clip.color.temperature))))
                vFilters.append("colortemperature=temperature=\(tempK)")
            }

            let opPoints: [(timeMs: Int64, value: Double, easing: KeyframeEasing)] = clip.hasKeyframes()
                ? clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.opacity, easing: $0.easing) }
                : []
            let hasOpacityAnim = opPoints.contains { abs($0.value - 1.0) > 0.01 }
            let isStaticOpacity = abs(clip.transform.opacity - 1.0) > 0.01

            if clip.hasKeyframes() {
                let contrastPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: ($0.contrast) * expMultiplier, easing: $0.easing) }
                let brightnessPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.brightness + (0.05 * clip.color.exposure), easing: $0.easing) }
                let saturationPoints = clip.sortedKeyframes.map { (timeMs: $0.timeMs, value: $0.saturation, easing: $0.easing) }

                let hasColorAnim = contrastPoints.contains { abs($0.value - 1.0) > 0.01 } ||
                                   brightnessPoints.contains { abs($0.value) > 0.01 } ||
                                   saturationPoints.contains { abs($0.value - 1.0) > 0.01 }

                if hasColorAnim || hasOpacityAnim {
                    let rawContrastExpr = buildFFmpegTimeExpression(points: contrastPoints, defaultValue: baseContrast)
                    let rawBrightnessExpr = buildFFmpegTimeExpression(points: brightnessPoints, defaultValue: baseBrightness)
                    let rawSaturationExpr = buildFFmpegTimeExpression(points: saturationPoints, defaultValue: clip.color.saturation)

                    if hasOpacityAnim {
                        let alphaExpr = buildFFmpegTimeExpression(points: opPoints, defaultValue: 1.0)
                        let cExpr = "(\(rawContrastExpr))*(\(alphaExpr))"
                        let bExpr = "(\(rawBrightnessExpr))+0.5*((\(alphaExpr))-1.0)"
                        vFilters.append("eq=eval=frame:contrast='\(cExpr)':brightness='\(bExpr)':saturation='\(rawSaturationExpr)'")
                    } else if isStaticOpacity {
                        let staticOp = String(format: "%.4f", max(0.0, min(1.0, clip.transform.opacity)))
                        let cExpr = "(\(rawContrastExpr))*\(staticOp)"
                        let bExpr = "(\(rawBrightnessExpr))+0.5*(\(staticOp)-1.0)"
                        vFilters.append("eq=eval=frame:contrast='\(cExpr)':brightness='\(bExpr)':saturation='\(rawSaturationExpr)'")
                    } else {
                        vFilters.append("eq=eval=frame:contrast='\(rawContrastExpr)':brightness='\(rawBrightnessExpr)':saturation='\(rawSaturationExpr)'")
                    }
                } else if baseContrast != 1.0 || baseBrightness != 0.0 || clip.color.saturation != 1.0 || isStaticOpacity {
                    let op = isStaticOpacity ? max(0.0, min(1.0, clip.transform.opacity)) : 1.0
                    let effContrast = baseContrast * op
                    let effBrightness = baseBrightness + 0.5 * (op - 1.0)
                    vFilters.append("eq=contrast=\(String(format: "%.4f", effContrast)):brightness=\(String(format: "%.4f", effBrightness)):saturation=\(String(format: "%.4f", clip.color.saturation))")
                }
            } else if baseContrast != 1.0 || baseBrightness != 0.0 || clip.color.saturation != 1.0 || isStaticOpacity {
                let op = isStaticOpacity ? max(0.0, min(1.0, clip.transform.opacity)) : 1.0
                let effContrast = baseContrast * op
                let effBrightness = baseBrightness + 0.5 * (op - 1.0)
                vFilters.append("eq=contrast=\(String(format: "%.4f", effContrast)):brightness=\(String(format: "%.4f", effBrightness)):saturation=\(String(format: "%.4f", clip.color.saturation))")
            }

            // F. Position Offset & Overlay onto Black Canvas
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
            clipDurations.append(clipDurationSec)
            totalExpectedDurationSec += clipDurationSec

            let vFilterStr = vFilters.joined(separator: ",")
            let xExpr = "(W-w)/2+(\(xOffsetExpr))"
            let yExpr = "(H-h)/2+(\(yOffsetExpr))"
            let durFormatted = String(format: "%.3f", clipDurationSec)

            // Video overlay onto black background with eof_action=pass, exact framerate and duration trim
            filterComplexParts.append("color=c=black:s=\(targetW)x\(targetH):d=\(durFormatted):r=\(config.targetFps)[bg\(idx)]")
            filterComplexParts.append("[\(idx):v]setpts=PTS-STARTPTS,\(vFilterStr)[fg\(idx)]")
            filterComplexParts.append("[bg\(idx)][fg\(idx)]overlay=x='\(xExpr)':y='\(yExpr)':eof_action=pass,fps=\(config.targetFps),setsar=1,trim=0:\(durFormatted),setpts=PTS-STARTPTS[v\(idx)]")

            // 2. Audio Filters with apad to guarantee duration matching
            if hasAudioTrack && !clip.isMuted {
                let vol = String(format: "%.2f", clip.volume)
                filterComplexParts.append("[\(idx):a]asetpts=PTS-STARTPTS,volume=\(vol),aformat=sample_rates=48000:channel_layouts=stereo,apad[a_pad\(idx)]")
                filterComplexParts.append("[a_pad\(idx)]atrim=0:\(durFormatted),asetpts=PTS-STARTPTS[a\(idx)]")
            } else {
                // Generate silent audio of exact duration so multi-clip concat never fails or desyncs
                filterComplexParts.append("aevalsrc=0:d=\(durFormatted):s=48000:c=stereo,atrim=0:\(durFormatted),asetpts=PTS-STARTPTS[a\(idx)]")
            }
        }

        // Step 3: Handle Clip Transitions (Cross Dissolve, Fade Black, Fade White) or Direct Cut
        let hasTransitions = project.clips.dropLast().contains { $0.transitionOut != .cut }
        var masterVideoStream = "[master_v_raw]"
        var masterAudioStream = "[master_a_raw]"

        if hasTransitions && preparedClipUrls.count >= 2 {
            var currentVTag = "[v0]"
            var currentATag = "[a0]"
            var currentOffset = clipDurations[0]

            for i in 0..<(preparedClipUrls.count - 1) {
                let clip = project.clips[i]
                let transType = clip.transitionOut
                let transDurSec = min(Double(clip.transitionDurationMs) / 1000.0, min(clipDurations[i], clipDurations[i + 1]) * 0.45)
                let nextVTag = "[v\(i + 1)]"
                let nextATag = "[a\(i + 1)]"
                let outVTag = (i == preparedClipUrls.count - 2) ? masterVideoStream : "[vx\(i + 1)]"
                let outATag = (i == preparedClipUrls.count - 2) ? masterAudioStream : "[ax\(i + 1)]"

                let xfadeName: String
                switch transType {
                case .crossDissolve: xfadeName = "fade"
                case .fadeBlack: xfadeName = "fadeblack"
                case .fadeWhite: xfadeName = "fadewhite"
                case .cut: xfadeName = "wipeleft"
                }

                if transType != .cut && transDurSec > 0.05 {
                    let transOffset = max(0.0, currentOffset - transDurSec)
                    filterComplexParts.append("\(currentVTag)\(nextVTag)xfade=transition=\(xfadeName):duration=\(String(format: "%.3f", transDurSec)):offset=\(String(format: "%.3f", transOffset))\(outVTag)")
                    filterComplexParts.append("\(currentATag)\(nextATag)acrossfade=d=\(String(format: "%.3f", transDurSec))\(outATag)")
                    currentOffset = transOffset + clipDurations[i + 1]
                    totalExpectedDurationSec -= transDurSec
                } else {
                    // Direct cut fallback for this pair
                    filterComplexParts.append("\(currentVTag)\(currentATag)\(nextVTag)\(nextATag)concat=n=2:v=1:a=1\(outVTag)\(outATag)")
                    currentOffset += clipDurations[i + 1]
                }

                currentVTag = outVTag
                currentATag = outATag
            }
        } else {
            // Direct concat
            var concatStreams = ""
            for idx in 0..<preparedClipUrls.count {
                concatStreams += "[v\(idx)][a\(idx)]"
            }
            filterComplexParts.append("\(concatStreams)concat=n=\(preparedClipUrls.count):v=1:a=1\(masterVideoStream)\(masterAudioStream)")
        }

        // Step 4: Text Overlays Rendering (with drawtext)
        var finalVideoStream = masterVideoStream
        let validTextOverlays = project.textOverlays.filter { !$0.text.isEmpty && $0.timelineEndMs > $0.timelineStartMs }

        if !validTextOverlays.isEmpty {
            var currentV = masterVideoStream
            for (tIdx, overlay) in validTextOverlays.enumerated() {
                let outTag = "[v_text\(tIdx)]"
                let escapedText = overlay.text.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: ":", with: "\\:")
                let scaledFontSize = max(14, Int(round(Double(overlay.fontSize) * overlay.scale * Double(targetH) / 640.0)))
                let startSec = String(format: "%.3f", Double(overlay.timelineStartMs) / 1000.0)
                let endSec = String(format: "%.3f", Double(overlay.timelineEndMs) / 1000.0)
                let posXExpr = "(w*\(String(format: "%.3f", overlay.posX))-text_w/2)"
                let posYExpr = "(h*\(String(format: "%.3f", overlay.posY))-text_h/2)"
                var dtArgs = "text='\(escapedText)':fontsize=\(scaledFontSize):fontcolor=0x\(overlay.textColorHex):x=\(posXExpr):y=\(posYExpr):enable='between(t,\(startSec),\(endSec))'"
                if let bgHex = overlay.backgroundColorHex, !bgHex.isEmpty {
                    dtArgs += ":box=1:boxcolor=0x\(bgHex)@0.75:boxborderw=6"
                }
                filterComplexParts.append("\(currentV)drawtext=\(dtArgs)\(outTag)")
                currentV = outTag
            }
            finalVideoStream = currentV
        }

        // Step 5: Secondary Audio Tracks Mixing
        let validAudioTracks = project.audioTracks.filter {
            !$0.isMuted && FileManager.default.fileExists(atPath: $0.url.path) && $0.durationMs > 0
        }
        var finalAudioStream = masterAudioStream

        if !validAudioTracks.isEmpty {
            var amixStreams = masterAudioStream
            for (aIdx, track) in validAudioTracks.enumerated() {
                let inIdx = preparedClipUrls.count + aIdx
                concatArgs += ["-i", track.url.path]
                let secTag = "[sec_a\(aIdx)]"
                let dSec = String(format: "%.3f", Double(track.durationMs) / 1000.0)
                var aFilters = ["atrim=0:\(dSec)", "asetpts=PTS-STARTPTS"]
                if track.fadeInMs > 0 {
                    aFilters.append("afade=t=in:st=0:d=\(String(format: "%.3f", Double(track.fadeInMs) / 1000.0))")
                }
                if track.fadeOutMs > 0 {
                    let outStart = max(0.0, (Double(track.durationMs) - Double(track.fadeOutMs)) / 1000.0)
                    aFilters.append("afade=t=out:st=\(String(format: "%.3f", outStart)):d=\(String(format: "%.3f", Double(track.fadeOutMs) / 1000.0))")
                }
                aFilters.append("volume=\(String(format: "%.2f", track.volume))")
                if track.timelineStartMs > 0 {
                    aFilters.append("adelay=\(track.timelineStartMs)|\(track.timelineStartMs)")
                }
                filterComplexParts.append("[\(inIdx):a]\(aFilters.joined(separator: ","))\(secTag)")
                amixStreams += secTag
            }
            let outMixTag = "[amix_out]"
            filterComplexParts.append("\(amixStreams)amix=inputs=\(1 + validAudioTracks.count):duration=first:dropout_transition=2\(outMixTag)")
            finalAudioStream = outMixTag
        }

        let filterComplexString = filterComplexParts.joined(separator: ";")

        concatArgs += [
            "-filter_complex", filterComplexString,
            "-map", finalVideoStream,
            "-map", finalAudioStream,
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

        onProgress(0.85, "Encoding master video (\(config.codec.shortLabel))...")

        let session = FFmpegKit.execute(withArguments: concatArgs)
        var code = session?.getReturnCode()

        // Fallback: If hardware encoder failed, retry with software encoder
        if !ReturnCode.isSuccess(code) && !ReturnCode.isCancel(code) {
            onProgress(0.88, "Retrying with software encoder fallback...")
            let swEncoder = (config.codec == .hevc) ? "libx265" : "libx264"
            var swArgs = concatArgs
            if let encIdx = swArgs.firstIndex(of: "-c:v"), encIdx + 1 < swArgs.count {
                swArgs[encIdx + 1] = swEncoder
            }
            let swSession = FFmpegKit.execute(withArguments: swArgs)
            code = swSession?.getReturnCode()
        }

        if isCancelled || ReturnCode.isCancel(code) {
            try? FileManager.default.removeItem(at: outputUrl)
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Export cancelled")
        }

        if ReturnCode.isSuccess(code), FileManager.default.fileExists(atPath: outputUrl.path) {
            onProgress(0.94, "Validating exported output integrity...")
            let valResult = validateExportedFile(
                url: outputUrl,
                expectedDurationSec: totalExpectedDurationSec,
                expectedWidth: targetW,
                expectedHeight: targetH,
                expectedFps: config.targetFps,
                shouldHaveAudio: project.clips.contains { !$0.isMuted } || !validAudioTracks.isEmpty
            )

            guard valResult.isValid else {
                try? FileManager.default.removeItem(at: outputUrl)
                return EditorExportResult(success: false, outputUrl: nil, errorMessage: valResult.error)
            }

            var photosNotice: String? = nil
            if config.saveToCameraRoll {
                onProgress(0.97, "Saving to Camera Roll...")
                let saved = await DirectDownloadEngine().saveVideoToPhotos(url: outputUrl)
                if !saved {
                    photosNotice = "Export rendered successfully, but could not be saved to Photos library (check Photos permissions)."
                }
            }

            onProgress(1.0, "Complete!")
            return EditorExportResult(success: true, outputUrl: outputUrl, errorMessage: photosNotice)
        } else {
            let logs = session?.getAllLogsAsString() ?? "Composition encoding failed"
            let err = logs.split(separator: "\n").suffix(6).joined(separator: "\n")
            try? FileManager.default.removeItem(at: outputUrl)
            return EditorExportResult(success: false, outputUrl: nil, errorMessage: "Render failure:\n\(err)")
        }
    }

    /// Evaluates piecewise keyframe interpolation expression over time `t` (seconds) matching preview easing curves exactly
    func buildFFmpegTimeExpression(
        points: [(timeMs: Int64, value: Double, easing: KeyframeEasing)],
        defaultValue: Double,
        multiplier: Double = 1.0
    ) -> String {
        let sorted = points.sorted { $0.timeMs < $1.timeMs }
        guard !sorted.isEmpty else {
            return String(format: "%.6f", defaultValue * multiplier)
        }
        if sorted.count == 1 {
            let v = sorted[0].value * multiplier
            return String(format: "%.6f", v)
        }

        var expr = String(format: "%.6f", sorted.last!.value * multiplier)
        for i in stride(from: sorted.count - 2, through: 0, by: -1) {
            let k0 = sorted[i]
            let k1 = sorted[i + 1]
            let t0 = Double(k0.timeMs) / 1000.0
            let t1 = Double(k1.timeMs) / 1000.0
            let v0 = k0.value * multiplier
            let v1 = k1.value * multiplier
            let span = max(0.0001, t1 - t0)

            // Normalized progress p in [0, 1]
            let pExpr = "((t-\(String(format: "%.6f", t0)))/\(String(format: "%.6f", span)))"
            let easeExpr: String
            switch k0.easing {
            case .linear:
                easeExpr = pExpr
            case .easeIn:
                easeExpr = "(\(pExpr)*\(pExpr))"
            case .easeOut:
                easeExpr = "(\(pExpr)*(2-\(pExpr)))"
            case .easeInOut:
                // Smoothstep: 3p^2 - 2p^3 (matches Swift KeyframeEasing.easeInOut)
                easeExpr = "(\(pExpr)*\(pExpr)*(3-2*\(pExpr)))"
            case .smooth:
                // Cosine ease: (1 - cos(PI * p)) / 2 (matches Swift KeyframeEasing.smooth)
                easeExpr = "((1-cos(PI*\(pExpr)))/2)"
            }

            let segExpr = "\(String(format: "%.6f", v0))+(\(String(format: "%.6f", v1 - v0)))*\(easeExpr)"
            expr = "if(lt(t,\(String(format: "%.6f", t1))),\(segExpr),\(expr))"
        }
        let firstT = Double(sorted.first!.timeMs) / 1000.0
        let firstV = sorted.first!.value * multiplier
        expr = "if(lt(t,\(String(format: "%.6f", firstT))),\(String(format: "%.6f", firstV)),\(expr))"
        return expr
    }

    /// Validates the exported video file: exists, non-zero size, playable, correct dimensions, duration within tolerance, and final frame decodable
    func validateExportedFile(
        url: URL,
        expectedDurationSec: Double,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedFps: Int,
        shouldHaveAudio: Bool
    ) -> (isValid: Bool, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (false, "Export validation error: Output file does not exist on disk.")
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 1024 else {
            return (false, "Export validation error: Output file size is 0 bytes or corrupted.")
        }

        let asset = AVURLAsset(url: url)
        let durSec = asset.duration.seconds
        guard durSec > 0.05 else {
            return (false, "Export validation error: Output video duration is zero.")
        }

        // Validate duration within acceptable margin (1.0s or 15% tolerance)
        let durTolerance = max(1.0, expectedDurationSec * 0.15)
        if abs(durSec - expectedDurationSec) > durTolerance {
            return (false, "Export validation error: Output duration (\(String(format: "%.2f", durSec))s) deviates too far from expected (\(String(format: "%.2f", expectedDurationSec))s).")
        }

        let videoTracks = asset.tracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            return (false, "Export validation error: No valid video track found in output file.")
        }

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let transformedSize = naturalSize.applying(transform)
        let actualW = Int(abs(transformedSize.width))
        let actualH = Int(abs(transformedSize.height))

        // Validate dimensions within 4px alignment margin
        if abs(actualW - expectedWidth) > 4 || abs(actualH - expectedHeight) > 4 {
            return (false, "Export validation error: Output dimensions (\(actualW)x\(actualH)) do not match expected (\(expectedWidth)x\(expectedHeight)).")
        }

        if shouldHaveAudio {
            let audioTracks = asset.tracks(withMediaType: .audio)
            if audioTracks.isEmpty {
                return (false, "Export validation error: Expected audio track was not present in the exported file.")
            }
        }

        // Verify final frame can be decoded with AVAssetImageGenerator
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let testTimeSec = max(0.0, durSec - 0.08)
        let testTime = CMTime(seconds: testTimeSec, preferredTimescale: 600)
        do {
            _ = try generator.copyCGImage(at: testTime, actualTime: nil)
            return (true, nil)
        } catch {
            return (false, "Export output validation failed to decode video frames: \(error.localizedDescription)")
        }
    }
}
