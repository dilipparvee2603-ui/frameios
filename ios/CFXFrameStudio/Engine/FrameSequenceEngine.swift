import Foundation
import AVFoundation
import Photos
import ffmpegkit

// MARK: - Sequence Format
enum SequenceFormat: String, CaseIterable, Identifiable {
    case png = "Lossless PNG (8-bit RGB)"
    case jpeg = "JPEG (High Quality 95%)"
    case tiff = "TIFF (VFX Master Uncompressed)"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        }
    }
}

// MARK: - Sequence FPS
enum SequenceFPS: String, CaseIterable, Identifiable {
    case source = "Native Source FPS"
    case fps60 = "60 FPS (Super Smooth)"
    case fps30 = "30 FPS (Standard)"
    case fps24 = "24 FPS (Cinematic)"
    case fps12 = "12 FPS (Anime / Stylized)"
    case fps1 = "1 FPS (Timelapse Keyframes)"

    var id: String { rawValue }

    var numericValue: Double? {
        switch self {
        case .source: return nil
        case .fps60: return 60.0
        case .fps30: return 30.0
        case .fps24: return 24.0
        case .fps12: return 12.0
        case .fps1: return 1.0
        }
    }
}

// MARK: - Sequence Destination
enum SequenceDestination: String, CaseIterable, Identifiable {
    case zipArchive = "ZIP Archive (Recommended for VFX / PC)"
    case photosAlbum = "Save to Camera Roll Album"
    case filesFolder = "Keep as Unzipped Folder in Files"

    var id: String { rawValue }
}

// MARK: - Sequence Export Result
struct SequenceExportResult {
    let success: Bool
    let outputUrl: URL?
    let frameCount: Int
    let totalSizeBytes: Int64
    let errorMessage: String?
}

// MARK: - Frame Sequence Engine
final class FrameSequenceEngine {
    static let shared = FrameSequenceEngine()

    private init() {}

    func cancel() {
        FFmpegKit.cancel()
    }

    // Export frame sequence
    func exportSequence(
        srcUrl: URL,
        startMs: Int64,
        endMs: Int64,
        fpsMode: SequenceFPS,
        format: SequenceFormat,
        destination: SequenceDestination,
        onProgress: @escaping (Float, Int) -> Void
    ) async -> SequenceExportResult {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let outputFolder = tempDir.appendingPathComponent("CFX_Sequence_\(timestamp)", isDirectory: true)

        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: srcUrl)
        let totalDuration = (try? await asset.load(.duration)) ?? .zero
        let totalSec = CMTimeGetSeconds(totalDuration)

        let clampedStartMs = max(0, startMs)
        let clampedEndMs = (endMs > clampedStartMs) ? endMs : Int64(totalSec * 1000)

        let startSec = Double(clampedStartMs) / 1000.0
        let targetDuration = max(0.05, Double(clampedEndMs - clampedStartMs) / 1000.0)

        // Calculate expected frame count
        var sourceFps = 30.0
        if let videoTracks = try? await asset.loadTracks(withMediaType: .video), let vTrack = videoTracks.first {
            sourceFps = Double(try? await vTrack.load(.nominalFrameRate) ?? 30.0)
            if sourceFps <= 0 { sourceFps = 30.0 }
        }

        let effectiveFps = fpsMode.numericValue ?? sourceFps
        let expectedFrames = max(1, Int(targetDuration * effectiveFps))

        // Build FFmpeg command
        var args: [String] = []

        if clampedStartMs > 0 {
            args += ["-ss", String(format: "%.3f", startSec)]
        }

        args += ["-i", srcUrl.path]

        if clampedEndMs > clampedStartMs {
            args += ["-t", String(format: "%.3f", targetDuration)]
        }

        // FPS filter
        if let fpsVal = fpsMode.numericValue {
            args += ["-vf", "fps=\(fpsVal)"]
        }

        // Quality / Codec settings
        switch format {
        case .png:
            args += ["-c:v", "png"]
        case .jpeg:
            args += ["-q:v", "2"]
        case .tiff:
            args += ["-c:v", "tiff"]
        }

        let framePattern = outputFolder.appendingPathComponent("frame_%04d.\(format.fileExtension)").path
        args += ["-y", framePattern]

        // Enable progress callback
        FFmpegKitConfig.enableStatisticsCallback { stats in
            guard let stats = stats else { return }
            let videoFrameNumber = stats.getVideoFrameNumber()
            let progress = min(1.0, max(0.0, Float(videoFrameNumber) / Float(expectedFrames)))
            DispatchQueue.main.async {
                onProgress(progress, videoFrameNumber)
            }
        }

        let session = FFmpegKit.execute(withArguments: args)
        FFmpegKitConfig.enableStatisticsCallback(nil)

        guard let returnCode = session?.getReturnCode(), returnCode.isValueSuccess() else {
            let logs = session?.getAllLogsAsString() ?? "Extraction failed"
            return SequenceExportResult(success: false, outputUrl: nil, frameCount: 0, totalSizeBytes: 0, errorMessage: logs)
        }

        // Count generated frames and size
        let files = (try? FileManager.default.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let actualFrameCount = files.count
        var totalBytes: Int64 = 0

        for file in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += Int64(size)
            }
        }

        guard actualFrameCount > 0 else {
            return SequenceExportResult(success: false, outputUrl: nil, frameCount: 0, totalSizeBytes: 0, errorMessage: "No frames extracted")
        }

        // Process based on destination
        switch destination {
        case .zipArchive:
            // Create ZIP archive using NSFileCoordinator forUploading
            var zipUrl: URL? = nil
            let coordinator = NSFileCoordinator()
            var coordError: NSError?

            coordinator.coordinate(readingItemAt: outputFolder, options: [.forUploading], error: &coordError) { zippedResult in
                let targetZip = tempDir.appendingPathComponent("CFX_Sequence_\(timestamp).zip")
                try? FileManager.default.removeItem(at: targetZip)
                do {
                    try FileManager.default.copyItem(at: zippedResult, to: targetZip)
                    zipUrl = targetZip
                } catch {
                    zipUrl = nil
                }
            }

            // Cleanup raw folder to save disk space
            try? FileManager.default.removeItem(at: outputFolder)

            if let finalZip = zipUrl {
                let zipSize = (try? finalZip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int(totalBytes)
                return SequenceExportResult(success: true, outputUrl: finalZip, frameCount: actualFrameCount, totalSizeBytes: Int64(zipSize), errorMessage: nil)
            } else {
                return SequenceExportResult(success: false, outputUrl: nil, frameCount: 0, totalSizeBytes: 0, errorMessage: "Failed to compress ZIP archive")
            }

        case .filesFolder:
            return SequenceExportResult(success: true, outputUrl: outputFolder, frameCount: actualFrameCount, totalSizeBytes: totalBytes, errorMessage: nil)

        case .photosAlbum:
            // Save to Camera Roll
            await saveFramesToPhotosAlbum(files: files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }))
            return SequenceExportResult(success: true, outputUrl: outputFolder, frameCount: actualFrameCount, totalSizeBytes: totalBytes, errorMessage: nil)
        }
    }

    private func saveFramesToPhotosAlbum(files: [URL]) async {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                for fileUrl in files {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: fileUrl, options: nil)
                }
            }, completionHandler: { _, _ in
                continuation.resume()
            })
        }
    }
}
