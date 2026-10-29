import Foundation
import AVFoundation
import Photos
import ffmpegkit

enum TrimPrecisionMode: String, CaseIterable, Identifiable {
    case frameAccurate = "Frame-Accurate (Micro Cut)"
    case fastPassthrough = "Fast Passthrough (Stream Copy)"

    var id: String { rawValue }
}

struct TrimResult {
    let success: Bool
    let outputUrl: URL?
    let errorMessage: String?
}

final class VideoTrimEngine {
    static let shared = VideoTrimEngine()

    private var activeSession: AVAssetExportSession?
    private var isCancelled: Bool = false

    private init() {}

    func cancel() {
        isCancelled = true
        activeSession?.cancelExport()
        activeSession = nil
        FFmpegKit.cancel()
    }

    func trimVideo(
        srcUrl: URL,
        startMs: Int64,
        endMs: Int64,
        includeAudio: Bool,
        mode: TrimPrecisionMode = .frameAccurate,
        onProgress: @escaping (Float) -> Void
    ) async -> TrimResult {
        let tempDir = FileManager.default.temporaryDirectory
        let tempOutUrl = tempDir.appendingPathComponent("CFX_Trim_\(Int(Date().timeIntervalSince1970 * 1000)).mp4")

        do {
            let asset = AVURLAsset(url: srcUrl)
            let duration = try await asset.load(.duration)
            let durationSec = CMTimeGetSeconds(duration)
            let maxMs = Int64(durationSec * 1000)

            let clampedStart = max(0, startMs)
            let clampedEnd = min(maxMs, max(clampedStart + 100, endMs))

            let startSec = Double(clampedStart) / 1000.0
            let endSec = Double(clampedEnd) / 1000.0
            let startTime = CMTime(seconds: startSec, preferredTimescale: 60000)
            let endTime = CMTime(seconds: endSec, preferredTimescale: 60000)
            let timeRange = CMTimeRange(start: startTime, end: endTime)

            var isSourceHEVC = false
            if let videoTracks = try? await asset.loadTracks(withMediaType: .video), let vTrack = videoTracks.first {
                if let descs = try? await vTrack.load(.formatDescriptions), let first = descs.first {
                    let subType = CMFormatDescriptionGetMediaSubType(first)
                    let fourCC = fourCharCodeToString(subType).lowercased()
                    if fourCC.contains("hvc") || fourCC.contains("hev") {
                        isSourceHEVC = true
                    }
                }
            }

            let exportAsset: AVAsset
            if includeAudio {
                exportAsset = asset
            } else {
                // Mute mode: create composition with video track ONLY
                let composition = AVMutableComposition()
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if let srcVideoTrack = videoTracks.first {
                    guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw NSError(domain: "CFXFrameStudio", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create muted video track"])
                    }
                    let timeRangeToInsert = CMTimeRange(start: .zero, duration: duration)
                    try compVideoTrack.insertTimeRange(timeRangeToInsert, of: srcVideoTrack, at: .zero)
                    compVideoTrack.preferredTransform = try await srcVideoTrack.load(.preferredTransform)
                }
                exportAsset = composition
            }

            let highestQualityPreset = isSourceHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality

            let chosenPreset: String
            if mode == .fastPassthrough && includeAudio {
                chosenPreset = AVAssetExportPresetPassthrough
            } else {
                chosenPreset = highestQualityPreset
            }

            // Attempt export session
            var exportSession = AVAssetExportSession(asset: exportAsset, presetName: chosenPreset)
            if exportSession == nil || !exportSession!.supportedFileTypes.contains(.mp4) {
                exportSession = AVAssetExportSession(asset: exportAsset, presetName: highestQualityPreset)
            }

            guard let session = exportSession else {
                return TrimResult(success: false, outputUrl: nil, errorMessage: "Could not create iOS export session")
            }

            if FileManager.default.fileExists(atPath: tempOutUrl.path) {
                try? FileManager.default.removeItem(at: tempOutUrl)
            }

            session.outputURL = tempOutUrl
            session.outputFileType = .mp4
            session.timeRange = timeRange
            session.shouldOptimizeForNetworkUse = true

            self.isCancelled = false
            self.activeSession = session
            defer {
                self.activeSession = nil
            }

            // Progress monitor task
            let progressTask = Task {
                while !Task.isCancelled {
                    let p = session.progress
                    DispatchQueue.main.async {
                        onProgress(p)
                    }
                    if session.status == .completed || session.status == .failed || session.status == .cancelled {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }

            // Universally compatible async export across iOS 15, 16, 17, 18
            await withCheckedContinuation { continuation in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }

            progressTask.cancel()

            if isCancelled || session.status == .cancelled {
                try? FileManager.default.removeItem(at: tempOutUrl)
                return TrimResult(success: false, outputUrl: nil, errorMessage: "OPERATION_CANCELLED")
            }

            if session.status == .completed {
                // Attempt to save to iOS Photos Library if supported
                var savedToPhotos = false
                do {
                    savedToPhotos = try await saveVideoToPhotos(fileUrl: tempOutUrl)
                } catch {
                    // Photos rejected the container/codec (e.g. PHPhotosErrorDomain from non-standard streams)
                    savedToPhotos = false
                }

                return TrimResult(
                    success: true,
                    outputUrl: tempOutUrl,
                    errorMessage: savedToPhotos ? nil : "NEEDS_SHARE_SHEET"
                )
            } else {
                // If AVAssetExportSession failed (e.g. hev1 tag, AC3/EAC3 Dolby audio tracks),
                // automatically fallback to FFmpeg stream copy trimming
                return await trimWithFFmpegFallback(
                    srcUrl: srcUrl,
                    startMs: clampedStart,
                    endMs: clampedEnd,
                    includeAudio: includeAudio,
                    tempOutUrl: tempOutUrl,
                    onProgress: onProgress
                )
            }
        } catch {
            return await trimWithFFmpegFallback(
                srcUrl: srcUrl,
                startMs: startMs,
                endMs: endMs,
                includeAudio: includeAudio,
                tempOutUrl: tempOutUrl,
                onProgress: onProgress
            )
        }
    }

    /// High-performance FFmpeg stream-copy trim fallback for videos with non-standard tags (hev1) or multi-channel Dolby audio
    private func trimWithFFmpegFallback(
        srcUrl: URL,
        startMs: Int64,
        endMs: Int64,
        includeAudio: Bool,
        tempOutUrl: URL,
        onProgress: @escaping (Float) -> Void
    ) async -> TrimResult {
        if isCancelled {
            return TrimResult(success: false, outputUrl: nil, errorMessage: "OPERATION_CANCELLED")
        }

        try? FileManager.default.removeItem(at: tempOutUrl)

        let startSec = Double(max(0, startMs)) / 1000.0
        let endSec = Double(max(startMs + 100, endMs)) / 1000.0

        let binScan = MKVRemuxEngine.fastBinaryScan(url: srcUrl)
        var isHEVC = binScan.hasHev1
        if !isHEVC, let session = FFprobeKit.getMediaInformation(srcUrl.path),
           let mediaInfo = session.getMediaInformation(),
           let streams = mediaInfo.getStreams() {
            for case let stream as StreamInformation in streams {
                if stream.getType()?.lowercased() == "video" {
                    let codec = stream.getCodec()?.lowercased() ?? ""
                    let tag = (stream.getProperty("codec_tag_string") as? String)?.lowercased() ?? ""
                    if codec.contains("hevc") || codec.contains("h265") || codec.contains("hev") || codec.contains("hvc") || tag.contains("hev") {
                        isHEVC = true
                        break
                    }
                }
            }
        }

        var args = [
            "-threads", "0",
            "-y",
            "-ss", String(format: "%.3f", startSec),
            "-to", String(format: "%.3f", endSec),
            "-i", srcUrl.path,
            "-map", "0:v:0",
            "-c:v", "copy"
        ]

        if isHEVC {
            args += ["-tag:v", "hvc1", "-bsf:v", "hevc_mp4toannexb"]
        }

        if includeAudio {
            args += ["-map", "0:a:0?", "-c:a", "aac", "-ac", "2", "-b:a", "192k"]
        } else {
            args += ["-an"]
        }

        args += [
            "-movflags", "+faststart",
            tempOutUrl.path
        ]

        let session = FFmpegKit.execute(withArguments: args)
        let code = session?.getReturnCode()

        if isCancelled || ReturnCode.isCancel(code) {
            try? FileManager.default.removeItem(at: tempOutUrl)
            return TrimResult(success: false, outputUrl: nil, errorMessage: "OPERATION_CANCELLED")
        }

        if ReturnCode.isSuccess(code),
           FileManager.default.fileExists(atPath: tempOutUrl.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: tempOutUrl.path),
           (attrs[.size] as? Int64 ?? 0) > 1024 {

            var savedToPhotos = false
            do {
                savedToPhotos = try await saveVideoToPhotos(fileUrl: tempOutUrl)
            } catch {
                savedToPhotos = false
            }

            return TrimResult(
                success: true,
                outputUrl: tempOutUrl,
                errorMessage: savedToPhotos ? nil : "NEEDS_SHARE_SHEET"
            )
        } else {
            let logs = session?.getAllLogsAsString() ?? session?.getFailStackTrace() ?? "Trimming failed"
            let lastLines = logs.split(separator: "\n").suffix(4).joined(separator: "\n")
            try? FileManager.default.removeItem(at: tempOutUrl)
            return TrimResult(success: false, outputUrl: nil, errorMessage: "Trim error:\n\(lastLines)")
        }
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
