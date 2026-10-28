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

        // Handle video orientation transform (portrait / rotated camera videos)
        let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
        let width = Int(isPortrait ? naturalSize.height : naturalSize.width)
        let height = Int(isPortrait ? naturalSize.width : naturalSize.height)
        let totalFrames = Int64(durationSec * fps)

        return VideoInfo(
            url: url,
            durationMs: durationMs,
            durationSec: durationSec,
            width: width,
            height: height,
            fps: fps,
            totalFrames: totalFrames
        )
    }

    func extractFrame(from url: URL, at timeMs: Int64) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Zero tolerances guarantee exact uncompressed frame extraction (no keyframe approximation)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cmTime = CMTime(value: CMTimeValue(timeMs), timescale: 1000)
        let (cgImage, _) = try await generator.image(at: cmTime)
        return UIImage(cgImage: cgImage)
    }

    func saveFrameToPhotos(image: UIImage, format: FrameFormat) async throws -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
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
}
