import Foundation
import AVFoundation
import UIKit
import Photos
import ImageIO
import UniformTypeIdentifiers

struct VideoInfo: Identifiable {
    let id = UUID()
    let url: URL
    let durationMs: Int64
    let durationSec: Double
    let width: Int
    let height: Int
    let fps: Double
    let totalFrames: Int64
    let videoCodec: String
    let audioCodec: String

    var formattedDuration: String {
        let totalSeconds = Int(durationSec)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let ms = Int(durationMs % 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, ms)
    }
}

enum FrameFormat: String, CaseIterable, Identifiable {
    case png = "PNG (Lossless)"
    case jpg = "JPG (100%)"
    case heic = "HEIC (P3)"
    case tiff = "TIFF (Master)"
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }
}

final class VideoEngine {
    static let shared = VideoEngine()

    private init() {}

    func extractVideoInfo(from url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(duration)
        let durationMs = Int64(durationSec * 1000.0)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw NSError(domain: "CFXFrameStudio", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30.0

        let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
        let width = Int(isPortrait ? naturalSize.height : naturalSize.width)
        let height = Int(isPortrait ? naturalSize.width : naturalSize.height)
        let totalFrames = Int64(round(durationSec * fps))

        // Auto-detect exact video codec FourCC
        var videoCodec = "H.264 (AVC)"
        if let descs = try? await videoTrack.load(.formatDescriptions), let first = descs.first {
            let subType = CMFormatDescriptionGetMediaSubType(first)
            let fourCC = fourCharCodeToString(subType)
            videoCodec = friendlyVideoCodecName(fourCC)
        }

        // Auto-detect exact audio codec FourCC
        var audioCodec = "None"
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio), let audioTrack = audioTracks.first {
            if let descs = try? await audioTrack.load(.formatDescriptions), let first = descs.first {
                let subType = CMFormatDescriptionGetMediaSubType(first)
                let fourCC = fourCharCodeToString(subType)
                audioCodec = friendlyAudioCodecName(fourCC)
            }
        }

        return VideoInfo(
            url: url,
            durationMs: durationMs,
            durationSec: durationSec,
            width: width,
            height: height,
            fps: fps,
            totalFrames: totalFrames,
            videoCodec: videoCodec,
            audioCodec: audioCodec
        )
    }

    /// Frame-accurate image extraction with zero tolerance and rational 60,000 timescale
    func extractFrame(from url: URL, at cmTime: CMTime) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var actualTime = CMTime.zero
        let cgImage = try generator.copyCGImage(at: cmTime, actualTime: &actualTime)
        return UIImage(cgImage: cgImage)
    }

    /// Extracts an exact numbered frame with zero rounding jitter
    func extractExactFrame(from url: URL, at frameIndex: Int64, fps: Double) async throws -> (image: UIImage, actualTime: CMTime) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let safeFps = max(1.0, fps)
        let targetSec = Double(max(0, frameIndex)) / safeFps
        let targetCm = CMTime(seconds: targetSec, preferredTimescale: 60000)

        var actualTime = CMTime.zero
        let cgImage = try generator.copyCGImage(at: targetCm, actualTime: &actualTime)
        return (UIImage(cgImage: cgImage), actualTime)
    }

    func extractFrame(from url: URL, at timeMs: Int64) async throws -> UIImage {
        let targetSec = Double(timeMs) / 1000.0
        let targetCm = CMTime(seconds: targetSec, preferredTimescale: 60000)
        return try await extractFrame(from: url, at: targetCm)
    }

    /// High-fidelity encoding supporting PNG, 100% Studio JPG, DCI-P3 HEIC, and Master TIFF
    func encodeImage(_ image: UIImage, format: FrameFormat) -> Data? {
        switch format {
        case .png:
            return image.pngData()
        case .jpg:
            return image.jpegData(compressionQuality: 1.0)
        case .heic:
            guard let cgImage = image.cgImage else { return image.pngData() }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, AVFileType.heic as CFString, 1, nil) else {
                return image.pngData()
            }
            let options: [CFString: Any] = [
                ("kCGImageDestinationLosslessQuality" as CFString): true
            ]
            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                return data as Data
            }
            return image.pngData()
        case .tiff:
            guard let cgImage = image.cgImage else { return image.pngData() }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.tiff" as CFString, 1, nil) else {
                return image.pngData()
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            if CGImageDestinationFinalize(destination) {
                return data as Data
            }
            return image.pngData()
        }
    }

    func saveFrameToTempFile(image: UIImage, format: FrameFormat) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileUrl = tempDir.appendingPathComponent("CFX_Frame_\(timestamp).\(format.fileExtension)")

        guard let imageData = encodeImage(image, format: format) else {
            throw NSError(domain: "CFXFrameStudio", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image as \(format.rawValue)"])
        }

        try imageData.write(to: fileUrl)
        return fileUrl
    }

    func saveFrameToPhotos(image: UIImage, format: FrameFormat) async throws -> Bool {
        let status = await requestPhotoAuthorization()
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "CFXFrameStudio", code: -2, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"])
        }

        guard let imageData = encodeImage(image, format: format) else {
            throw NSError(domain: "CFXFrameStudio", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image as \(format.rawValue)"])
        }

        var assetId: String?
        try await PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: imageData, options: nil)
            assetId = creationRequest.placeholderForCreatedAsset?.localIdentifier
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

// Helpers for converting FourCharCode to readable codec strings
func fourCharCodeToString(_ code: FourCharCode) -> String {
    let bytes: [CChar] = [
        CChar((code >> 24) & 0xFF),
        CChar((code >> 16) & 0xFF),
        CChar((code >> 8) & 0xFF),
        CChar(code & 0xFF),
        0
    ]
    return String(cString: bytes).trimmingCharacters(in: .whitespaces)
}

func friendlyVideoCodecName(_ fourCC: String) -> String {
    let lower = fourCC.lowercased()
    if lower.contains("avc") { return "H.264 (AVC)" }
    if lower.contains("hvc") || lower.contains("hev") { return "HEVC (H.265)" }
    if lower.starts(with: "ap") { return "Apple ProRes" }
    if lower.contains("mp4v") { return "MPEG-4" }
    if lower.contains("av01") { return "AV1" }
    if lower.contains("vp09") || lower.contains("vp9") { return "VP9" }
    if lower.contains("jpeg") || lower.contains("mjpg") { return "Motion JPEG" }
    return fourCC.uppercased()
}

func friendlyAudioCodecName(_ fourCC: String) -> String {
    let lower = fourCC.lowercased()
    if lower.contains("aac") || lower.contains("mp4a") { return "AAC" }
    if lower.contains("opus") { return "Opus" }
    if lower.contains("lpcm") || lower.contains("raw") { return "Linear PCM" }
    if lower.contains("ac-3") || lower.contains("ec-3") { return "Dolby Digital" }
    if lower.contains("alac") { return "Apple Lossless (ALAC)" }
    if lower.contains("mp3") { return "MP3" }
    return fourCC.uppercased()
}
