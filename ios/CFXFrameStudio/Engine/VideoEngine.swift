import Foundation
import AVFoundation
import UIKit
import Photos

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
    case png = "PNG"
    case jpg = "JPG"
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpg: return "jpg"
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
        let totalFrames = Int64(durationSec * fps)

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

    func extractFrame(from url: URL, at timeMs: Int64) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cmTime = CMTime(value: CMTimeValue(timeMs), timescale: 1000)
        let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
        return UIImage(cgImage: cgImage)
    }

    func saveFrameToTempFile(image: UIImage, format: FrameFormat) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileUrl = tempDir.appendingPathComponent("CFX_Frame_\(timestamp).\(format.fileExtension)")

        let data: Data?
        switch format {
        case .png:
            data = image.pngData()
        case .jpg:
            data = image.jpegData(compressionQuality: 0.95)
        }

        guard let imageData = data else {
            throw NSError(domain: "CFXFrameStudio", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
        }

        try imageData.write(to: fileUrl)
        return fileUrl
    }

    func saveFrameToPhotos(image: UIImage, format: FrameFormat) async throws -> Bool {
        let status = await requestPhotoAuthorization()
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "CFXFrameStudio", code: -2, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"])
        }

        let data: Data?
        switch format {
        case .png:
            data = image.pngData()
        case .jpg:
            data = image.jpegData(compressionQuality: 0.95)
        }

        guard let imageData = data else {
            throw NSError(domain: "CFXFrameStudio", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
        }

        try await PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: imageData, options: nil)
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
