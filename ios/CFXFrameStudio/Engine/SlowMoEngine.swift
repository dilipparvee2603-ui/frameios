import Foundation
import ffmpegkit
import Photos
import AVFoundation

enum SlowMoInterpolationMode: String, CaseIterable, Identifiable, Codable {
    case opticalFlow = "Optical Flow (MCI)"
    case frameBlend = "Frame Blend (Motion Blur)"
    case sensorNative = "Sensor Native (Conform)"
    case nearest = "Nearest Frame (Fast)"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .opticalFlow:
            return "Synthesizes brand-new in-between frames using motion vectors for buttery smooth slow-mo"
        case .frameBlend:
            return "Smoothly averages adjacent frames to simulate cinematic high-speed motion blur"
        case .sensorNative:
            return "Conforms 60/120/240fps footage to 24/30fps without duplicating or interpolating frames"
        case .nearest:
            return "Simple frame duplication for ultra-fast processing and quick previews"
        }
    }
}

enum SlowMoAudioMode: String, CaseIterable, Identifiable, Codable {
    case pitchPreserved = "Preserve Pitch"
    case vinylPitch = "Deep Vinyl Slowdown"
    case muted = "Mute Audio"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .pitchPreserved:
            return "Slows down audio while maintaining natural voice and music pitch"
        case .vinylPitch:
            return "Lowers pitch proportionally for a dramatic trailer rumble sound effect"
        case .muted:
            return "Strips audio track completely for clean visual B-roll"
        }
    }
}

struct SlowMoResult {
    let success: Bool
    let outputUrl: URL?
    let errorMessage: String?
}

final class SlowMoEngine {
    static let shared = SlowMoEngine()

    private var isCancelled: Bool = false

    private init() {}

    func cancel() {
        isCancelled = true
        FFmpegKit.cancel()
    }

    /// Generates smooth percentage-based slow-motion video with optical flow or frame blending
    func createSlowMotion(
        sourceUrl: URL,
        speedPercentage: Double, // 1.0 to 100.0 (e.g. 50.0 for 2x slow-mo, 25.0 for 4x)
        targetFps: Int = 60,
        interpolationMode: SlowMoInterpolationMode = .opticalFlow,
        audioMode: SlowMoAudioMode = .pitchPreserved,
        inPointMs: Int64 = 0,
        outPointMs: Int64 = 0,
        totalSourceDurationMs: Int64 = 0,
        onProgress: @escaping (Double, String) -> Void
    ) async -> SlowMoResult {
        isCancelled = false

        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let outputUrl = tempDir.appendingPathComponent("CFX_SlowMo_\(timestamp).mp4")

        try? FileManager.default.removeItem(at: outputUrl)

        let clampedPercentage = max(1.0, min(1600.0, speedPercentage))
        let speedMultiplier = clampedPercentage / 100.0
        let setptsMultiplier = 1.0 / speedMultiplier

        let startSec = Double(max(0, inPointMs)) / 1000.0
        let endSec: Double
        if outPointMs > inPointMs {
            endSec = Double(outPointMs) / 1000.0
        } else if totalSourceDurationMs > 0 {
            endSec = Double(totalSourceDurationMs) / 1000.0
        } else {
            endSec = 0.0
        }

        let clipDuration = max(0.1, (endSec > startSec) ? (endSec - startSec) : Double(totalSourceDurationMs) / 1000.0)
        let expectedOutputDurationSec = clipDuration * setptsMultiplier

        // Construct video filter graph
        let videoFilter: String
        if speedMultiplier >= 1.0 {
            // Fast motion / hyperlapse: accelerate PTS and conform to target FPS
            videoFilter = "setpts=\(String(format: "%.4f", setptsMultiplier))*PTS,fps=\(targetFps)"
        } else {
            // Slow motion: apply requested interpolation mode
            switch interpolationMode {
            case .opticalFlow:
                videoFilter = "setpts=\(String(format: "%.4f", setptsMultiplier))*PTS,minterpolate=fps=\(targetFps):mi_mode=mci:mc_mode=obmc:me_mode=bidir"
            case .frameBlend:
                videoFilter = "setpts=\(String(format: "%.4f", setptsMultiplier))*PTS,tblend=all_mode=average,framerate=fps=\(targetFps)"
            case .sensorNative:
                videoFilter = "setpts=\(String(format: "%.4f", setptsMultiplier))*PTS,fps=\(targetFps)"
            case .nearest:
                videoFilter = "setpts=\(String(format: "%.4f", setptsMultiplier))*PTS"
            }
        }

        var args = [
            "-threads", "0",
            "-y"
        ]

        // Fast seeking if trim sub-range is specified
        if startSec > 0 {
            args += ["-ss", String(format: "%.3f", startSec)]
        }
        if endSec > startSec {
            args += ["-to", String(format: "%.3f", endSec)]
        }

        args += [
            "-i", sourceUrl.path,
            "-vf", videoFilter,
            "-c:v", "h264_videotoolbox",
            "-b:v", "28M",
            "-maxrate", "36M",
            "-profile:v", "high",
            "-allow_sw", "1",
            "-pix_fmt", "yuv420p",
            "-colorspace", "1",
            "-color_primaries", "1",
            "-color_trc", "1"
        ]

        // Audio filter
        if audioMode == .muted {
            args += ["-an"]
        } else if audioMode == .pitchPreserved {
            let atempoChain = buildAtempoChain(speed: speedMultiplier)
            args += [
                "-af", atempoChain,
                "-c:a", "aac",
                "-b:a", "320k"
            ]
        } else if audioMode == .vinylPitch {
            let targetSampleRate = max(8000, min(96000, Int(round(44100.0 * speedMultiplier))))
            let pitchFilter = "asetrate=\(targetSampleRate),aresample=44100"
            args += [
                "-af", pitchFilter,
                "-c:a", "aac",
                "-b:a", "320k"
            ]
        }

        args += [
            "-movflags", "+faststart",
            outputUrl.path
        ]

        // Enable real-time statistics callback
        FFmpegKitConfig.enableStatisticsCallback { stats in
            guard let stats = stats else { return }
            let timeMs = Double(stats.getTime())
            let speedVal = stats.getSpeed()
            let speedText = speedVal > 0 ? String(format: "%.1fx", speedVal) : ""

            let totalExpectedMs = expectedOutputDurationSec * 1000.0
            var fraction = 0.0
            if totalExpectedMs > 0 {
                fraction = min(0.99, max(0.01, timeMs / totalExpectedMs))
            } else if timeMs > 0 {
                fraction = min(0.95, timeMs / 60000.0)
            }

            DispatchQueue.main.async {
                onProgress(fraction, speedText)
            }
        }

        defer {
            FFmpegKitConfig.enableStatisticsCallback(nil)
        }

        let session = FFmpegKit.execute(withArguments: args)
        let code = session?.getReturnCode()

        if isCancelled || ReturnCode.isCancel(code) {
            try? FileManager.default.removeItem(at: outputUrl)
            return SlowMoResult(success: false, outputUrl: nil, errorMessage: "OPERATION_CANCELLED")
        }

        if ReturnCode.isSuccess(code),
           FileManager.default.fileExists(atPath: outputUrl.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: outputUrl.path),
           (attrs[.size] as? Int64 ?? 0) > 1024 {

            return SlowMoResult(
                success: true,
                outputUrl: outputUrl,
                errorMessage: nil
            )
        } else {
            let logs = session?.getAllLogsAsString() ?? session?.getFailStackTrace() ?? "Slow motion processing failed"
            let lastLines = logs.split(separator: "\n").suffix(5).joined(separator: "\n")
            try? FileManager.default.removeItem(at: outputUrl)
            return SlowMoResult(success: false, outputUrl: nil, errorMessage: "Processing error:\n\(lastLines)")
        }
    }

    /// Public method to export an applied slow-mo video to the user's Photos Camera Roll
    func exportToPhotos(fileUrl: URL) async throws -> Bool {
        return try await saveVideoToPhotos(fileUrl: fileUrl)
    }

    /// Chains multiple atempo filters since atempo only accepts multipliers between 0.5 and 2.0
    private func buildAtempoChain(speed: Double) -> String {
        var remaining = max(0.01, min(2.0, speed))
        var filters: [String] = []
        while remaining < 0.5 {
            filters.append("atempo=0.5")
            remaining /= 0.5
        }
        while remaining > 2.0 {
            filters.append("atempo=2.0")
            remaining /= 2.0
        }
        filters.append(String(format: "atempo=%.4f", remaining))
        return filters.joined(separator: ",")
    }

    private func saveVideoToPhotos(fileUrl: URL) async throws -> Bool {
        let status = await requestPhotoAuthorization()
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "CFXFrameStudio", code: -5, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"])
        }

        var assetId: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileUrl)
            assetId = request?.placeholderForCreatedAsset?.localIdentifier
        }
        if let id = assetId {
            StorageManager.shared.trackSavedAsset(localIdentifier: id)
        }
        return true
    }

    private func requestPhotoAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
