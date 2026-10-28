import Foundation
import AVFoundation
import Photos

struct TrimResult {
    let success: Bool
    let outputUrl: URL?
    let errorMessage: String?
}

final class VideoTrimEngine {
    static let shared = VideoTrimEngine()

    private init() {}

    func trimVideo(
        srcUrl: URL,
        startMs: Int64,
        endMs: Int64,
        includeAudio: Bool,
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

            let startTime = CMTime(value: CMTimeValue(clampedStart), timescale: 1000)
            let endTime = CMTime(value: CMTimeValue(clampedEnd), timescale: 1000)
            let timeRange = CMTimeRange(start: startTime, end: endTime)

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

            // Attempt fast passthrough stream copy first
            var exportSession = AVAssetExportSession(asset: exportAsset, presetName: AVAssetExportPresetPassthrough)
            if exportSession == nil || !exportSession!.supportedFileTypes.contains(.mp4) {
                exportSession = AVAssetExportSession(asset: exportAsset, presetName: AVAssetExportPresetHighestQuality)
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

            await session.export()
            progressTask.cancel()

            if session.status == .completed {
                // Save to iOS Photos Library
                let saved = try await saveVideoToPhotos(fileUrl: tempOutUrl)
                try? FileManager.default.removeItem(at: tempOutUrl)

                if saved {
                    return TrimResult(success: true, outputUrl: tempOutUrl, errorMessage: nil)
                } else {
                    return TrimResult(success: false, outputUrl: nil, errorMessage: "Failed to save trimmed video to Camera Roll")
                }
            } else {
                let err = session.error?.localizedDescription ?? "Export failed"
                try? FileManager.default.removeItem(at: tempOutUrl)
                return TrimResult(success: false, outputUrl: nil, errorMessage: err)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempOutUrl)
            return TrimResult(success: false, outputUrl: nil, errorMessage: error.localizedDescription)
        }
    }

    private func saveVideoToPhotos(fileUrl: URL) async throws -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "CFXFrameStudio", code: -5, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"])
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileUrl)
        }
        return true
    }
}
