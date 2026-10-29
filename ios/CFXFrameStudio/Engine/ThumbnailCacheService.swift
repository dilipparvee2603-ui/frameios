import Foundation
import UIKit
import AVFoundation

// MARK: - High-Efficiency Timeline Thumbnail Cache
final class ThumbnailCacheService {
    static let shared = ThumbnailCacheService()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightGenerators: [UUID: AVAssetImageGenerator] = [:]
    private let queue = DispatchQueue(label: "com.cfx.framestudio.thumbnails", qos: .userInitiated)

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 1024 * 1024 * 60 // 60MB max RAM
    }

    func cacheKey(clipId: UUID, timestampMs: Int64) -> NSString {
        "\(clipId.uuidString)_\(timestampMs)" as NSString
    }

    func cachedThumbnail(clipId: UUID, timestampMs: Int64) -> UIImage? {
        cache.object(forKey: cacheKey(clipId: clipId, timestampMs: timestampMs))
    }

    /// Generates thumbnail strips for a clip across its trimmed range
    func generateThumbnails(
        for clip: EditorClip,
        count: Int = 8,
        completion: @escaping ([UIImage]) -> Void
    ) {
        let spanMs = clip.sourceTrimmedDurationMs
        guard spanMs > 0 else {
            completion([])
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            let asset = AVURLAsset(url: clip.sourceUrl)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            var times: [NSValue] = []
            for i in 0..<count {
                let fraction = Double(i) / Double(max(1, count - 1))
                let timeMs = clip.sourceInPointMs + Int64(fraction * Double(spanMs))
                let cmTime = CMTime(value: timeMs, timescale: 1000)
                times.append(NSValue(time: cmTime))
            }

            var thumbnails: [UIImage] = []
            for val in times {
                let cmTime = val.timeValue
                let ms = Int64(CMTimeGetSeconds(cmTime) * 1000.0)

                if let cached = self.cachedThumbnail(clipId: clip.id, timestampMs: ms) {
                    thumbnails.append(cached)
                } else if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                    let image = UIImage(cgImage: cgImage)
                    self.cache.setObject(image, forKey: self.cacheKey(clipId: clip.id, timestampMs: ms))
                    thumbnails.append(image)
                }
            }

            DispatchQueue.main.async {
                completion(thumbnails)
            }
        }
    }

    func cancel(clipId: UUID) {
        queue.async { [weak self] in
            self?.inFlightGenerators[clipId]?.cancelAllCGImageGeneration()
            self?.inFlightGenerators.removeValue(forKey: clipId)
        }
    }
}
