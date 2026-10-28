import Foundation
import UIKit
import Photos

enum CropRatio: String, CaseIterable, Identifiable {
    case free = "Free"
    case r1_1 = "1:1"
    case r4_5 = "4:5"
    case r16_9 = "16:9"
    case r9_16 = "9:16"
    case r4_3 = "4:3"
    case r3_2 = "3:2"
    case r2_3 = "2:3"

    var id: String { rawValue }

    var dimensions: (CGFloat, CGFloat)? {
        switch self {
        case .free:
            return nil
        case .r1_1:
            return (1.0, 1.0)
        case .r4_5:
            return (4.0, 5.0)
        case .r16_9:
            return (16.0, 9.0)
        case .r9_16:
            return (9.0, 16.0)
        case .r4_3:
            return (4.0, 3.0)
        case .r3_2:
            return (3.0, 2.0)
        case .r2_3:
            return (2.0, 3.0)
        }
    }

    var subtitle: String {
        switch self {
        case .free:
            return "Original"
        case .r1_1:
            return "Square / Feed"
        case .r4_5:
            return "IG Portrait"
        case .r16_9:
            return "Widescreen / YT"
        case .r9_16:
            return "Story / Reel / Shorts"
        case .r4_3:
            return "Classic Photo"
        case .r3_2:
            return "35mm DSLR"
        case .r2_3:
            return "35mm Portrait"
        }
    }
}

enum CropFormat: String, CaseIterable, Identifiable {
    case png = "PNG (Lossless)"
    case jpg = "JPG (100% Quality)"

    var id: String { rawValue }

    var extensionString: String {
        switch self {
        case .png: return "png"
        case .jpg: return "jpg"
        }
    }
}

struct ImageCropEngine {

    static func computeCropRect(imageSize: CGSize, ratio: CropRatio) -> CGRect {
        let w = imageSize.width
        let h = imageSize.height
        guard let (rw, rh) = ratio.dimensions, w > 0, h > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }

        let targetRatio = rw / rh
        let currentRatio = w / h

        if currentRatio > targetRatio {
            // Wider than target ratio: crop width
            let targetWidth = h * targetRatio
            let x = (w - targetWidth) / 2.0
            return CGRect(x: x, y: 0, width: targetWidth, height: h)
        } else {
            // Taller than target ratio: crop height
            let targetHeight = w / targetRatio
            let y = (h - targetHeight) / 2.0
            return CGRect(x: 0, y: y, width: w, height: targetHeight)
        }
    }

    static func computeDefaultUnitRect(imageSize: CGSize, ratio: CropRatio) -> CGRect {
        let rect = computeCropRect(imageSize: imageSize, ratio: ratio)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1.0, height: 1.0)
        }
        return CGRect(
            x: rect.origin.x / imageSize.width,
            y: rect.origin.y / imageSize.height,
            width: rect.size.width / imageSize.width,
            height: rect.size.height / imageSize.height
        )
    }

    static func cropImage(
        _ image: UIImage,
        to rect: CGRect,
        rotationDegrees: Int = 0,
        isFlipped: Bool = false
    ) -> UIImage? {
        guard let normalized = image.normalizedForCropping() else { return nil }
        guard let cgImage = normalized.cgImage else { return nil }

        let scale = normalized.scale
        let pixelRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        ).integral

        let safeX = max(0, min(pixelRect.origin.x, CGFloat(cgImage.width - 1)))
        let safeY = max(0, min(pixelRect.origin.y, CGFloat(cgImage.height - 1)))
        let safeWidth = max(1, min(pixelRect.size.width, CGFloat(cgImage.width) - safeX))
        let safeHeight = max(1, min(pixelRect.size.height, CGFloat(cgImage.height) - safeY))

        let safeRect = CGRect(x: safeX, y: safeY, width: safeWidth, height: safeHeight).integral

        guard let croppedCg = cgImage.cropping(to: safeRect) else { return nil }
        var result = UIImage(cgImage: croppedCg, scale: 1.0, orientation: .up)

        let normRotation = ((rotationDegrees % 360) + 360) % 360
        if normRotation != 0 || isFlipped {
            if let transformed = result.transformed(rotationDegrees: normRotation, isFlipped: isFlipped) {
                result = transformed
            }
        }

        return result
    }

    static func saveToTempFile(image: UIImage, format: CropFormat) throws -> URL {
        let ext = format.extensionString
        let filename = "CFX_Crop_\(Int(Date().timeIntervalSince1970)).\(ext)"
        let fileUrl = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fileUrl.path) {
            try? FileManager.default.removeItem(at: fileUrl)
        }

        let data: Data?
        switch format {
        case .png:
            data = image.pngData()
        case .jpg:
            data = image.jpegData(compressionQuality: 1.0)
        }

        guard let validData = data else {
            throw NSError(domain: "ImageCropEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to compress cropped image data."])
        }

        try validData.write(to: fileUrl, options: .atomic)
        return fileUrl
    }

    static func saveToPhotos(image: UIImage, format: CropFormat) async throws -> URL {
        let tempUrl = try saveToTempFile(image: image, format: format)

        let status = await requestPhotoAuthorization()
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "ImageCropEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Photos access not granted."])
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: tempUrl, options: nil)
        }

        return tempUrl
    }

    private static func requestPhotoAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

// MARK: - UIImage Geometry Helpers
private extension UIImage {
    func normalizedForCropping() -> UIImage? {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalizedImage
    }

    func transformed(rotationDegrees: Int, isFlipped: Bool) -> UIImage? {
        let radians = CGFloat(rotationDegrees) * .pi / 180.0
        var newSize = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: radians)).integral.size
        newSize.width = abs(newSize.width)
        newSize.height = abs(newSize.height)

        UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }

        context.translateBy(x: newSize.width / 2.0, y: newSize.height / 2.0)
        context.rotate(by: radians)
        if isFlipped {
            context.scaleBy(x: -1.0, y: 1.0)
        }

        draw(in: CGRect(x: -size.width / 2.0, y: -size.height / 2.0, width: size.width, height: size.height))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}
