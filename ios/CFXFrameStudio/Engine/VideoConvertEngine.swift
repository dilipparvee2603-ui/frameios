import Foundation
import AVFoundation
import Photos
import UIKit

enum ExportContainer: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case mov = "MOV"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        }
    }

    var avFileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }
}

enum ExportCodec: String, CaseIterable, Identifiable {
    case auto = "Auto (Lossless)"
    case h264 = "H.264 (AVC)"
    case hevc = "HEVC (H.265)"
    case prores = "ProRes 422"

    var id: String { rawValue }

    func preset(for container: ExportContainer) -> String {
        switch self {
        case .auto:
            return AVAssetExportPresetPassthrough
        case .h264:
            return AVAssetExportPresetHighestQuality
        case .hevc:
            return AVAssetExportPresetHEVCHighestQuality
        case .prores:
            return AVAssetExportPresetAppleProRes422LPCM
        }
    }
}

struct ConvertResult {
    let success: Bool
    let outputUrl: URL?
    let errorMessage: String?
}

final class VideoConvertEngine {
    static let shared = VideoConvertEngine()

    private init() {}

    func convertVideo(
        srcUrl: URL,
        targetContainer: ExportContainer,
        targetCodec: ExportCodec,
        includeAudio: Bool,
        onProgress: @escaping (Float) -> Void
    ) async -> ConvertResult {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let tempOutUrl = tempDir.appendingPathComponent("CFX_Convert_\(timestamp).\(targetContainer.fileExtension)")

        do {
            let asset = AVURLAsset(url: srcUrl)
            let duration = try await asset.load(.duration)

            let exportAsset: AVAsset
            if includeAudio {
                exportAsset = asset
            } else {
                // Strip audio: create video-only composition
                let composition = AVMutableComposition()
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if let srcVideoTrack = videoTracks.first {
                    guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw NSError(domain: "CFXFrameStudio", code: -10, userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"])
                    }
                    let timeRangeToInsert = CMTimeRange(start: .zero, duration: duration)
                    try compVideoTrack.insertTimeRange(timeRangeToInsert, of: srcVideoTrack, at: .zero)
                    compVideoTrack.preferredTransform = try await srcVideoTrack.load(.preferredTransform)
                }
                exportAsset = composition
            }

            var chosenPreset = targetCodec.preset(for: targetContainer)

            // ProRes is only supported in MOV
            if targetCodec == .prores && targetContainer != .mov {
                chosenPreset = AVAssetExportPresetHEVCHighestQuality
            }

            // Check if passthrough is supported; if not, fall back to highest quality
            var exportSession = AVAssetExportSession(asset: exportAsset, presetName: chosenPreset)
            if exportSession == nil || !exportSession!.supportedFileTypes.contains(targetContainer.avFileType) {
                chosenPreset = (targetCodec == .hevc) ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
                exportSession = AVAssetExportSession(asset: exportAsset, presetName: chosenPreset)
            }

            guard let session = exportSession else {
                return ConvertResult(success: false, outputUrl: nil, errorMessage: "Could not create conversion export session")
            }

            if FileManager.default.fileExists(atPath: tempOutUrl.path) {
                try? FileManager.default.removeItem(at: tempOutUrl)
            }

            session.outputURL = tempOutUrl
            session.outputFileType = targetContainer.avFileType
            session.shouldOptimizeForNetworkUse = true

            // Progress monitor
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

            // Universally compatible async export
            await withCheckedContinuation { continuation in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }

            progressTask.cancel()

            if session.status == .completed {
                // Try saving to Photos library if format is supported by Camera Roll
                var savedToPhotos = false
                if targetContainer == .mp4 || targetContainer == .mov {
                    savedToPhotos = (try? await saveVideoToPhotos(fileUrl: tempOutUrl)) ?? false
                }

                return ConvertResult(
                    success: true,
                    outputUrl: tempOutUrl,
                    errorMessage: savedToPhotos ? nil : "Video converted! Available in Files/Share."
                )
            } else {
                let err = session.error?.localizedDescription ?? "Conversion failed"
                try? FileManager.default.removeItem(at: tempOutUrl)
                return ConvertResult(success: false, outputUrl: nil, errorMessage: err)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempOutUrl)
            return ConvertResult(success: false, outputUrl: nil, errorMessage: error.localizedDescription)
        }
    }

    private func saveVideoToPhotos(fileUrl: URL) async throws -> Bool {
        let status = await requestPhotoAuthorization()
        guard status == .authorized || status == .limited else {
            return false
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileUrl)
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
