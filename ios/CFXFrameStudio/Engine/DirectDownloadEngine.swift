import Foundation
import AVFoundation
import Photos
import UIKit

struct MediaInspection {
    let isVideo: Bool
    let isImage: Bool
    let container: String
    let videoCodec: String
    let audioCodec: String
    let width: Int
    let height: Int
    let durationSec: Double
    let isPhotosCompatible: Bool
    let incompatibilityReason: String?
}

@MainActor
final class DirectDownloadEngine: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0.0
    @Published var bytesWritten: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var downloadSpeedMBs: Double = 0.0
    @Published var downloadedFileUrl: URL? = nil
    @Published var mediaInspection: MediaInspection? = nil
    @Published var savedToPhotos: Bool = false
    @Published var errorMessage: String? = nil

    private var downloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession?
    private var lastSpeedCheckTime: Date = Date()
    private var lastSpeedBytes: Int64 = 0

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 3600.0
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func startDownload(urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            self.errorMessage = "Please enter a valid HTTP or HTTPS direct link."
            return
        }

        reset()
        self.isDownloading = true
        self.lastSpeedCheckTime = Date()
        self.lastSpeedBytes = 0

        let task = urlSession?.downloadTask(with: url)
        self.downloadTask = task
        task?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        progress = 0.0
    }

    func reset() {
        cancelDownload()
        downloadedFileUrl = nil
        mediaInspection = nil
        savedToPhotos = false
        errorMessage = nil
        progress = 0.0
        bytesWritten = 0
        totalBytes = 0
        downloadSpeedMBs = 0.0
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            self.bytesWritten = totalBytesWritten
            self.totalBytes = totalBytesExpectedToWrite

            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }

            let now = Date()
            let timeDiff = now.timeIntervalSince(self.lastSpeedCheckTime)
            if timeDiff >= 0.5 {
                let bytesDiff = totalBytesWritten - self.lastSpeedBytes
                let speedBps = Double(bytesDiff) / timeDiff
                self.downloadSpeedMBs = max(0.0, speedBps / (1024.0 * 1024.0))
                self.lastSpeedCheckTime = now
                self.lastSpeedBytes = totalBytesWritten
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        Task { @MainActor in
            do {
                // Determine destination filename
                let originalName = downloadTask.response?.suggestedFilename
                    ?? downloadTask.originalRequest?.url?.lastPathComponent
                    ?? "CFX_Download_\(Int(Date().timeIntervalSince1970))"

                let safeFilename = sanitizeFilename(originalName)

                // Save to user-visible Documents folder (On My iPhone > CFX Studio)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let destinationUrl = docs.appendingPathComponent(safeFilename)

                if FileManager.default.fileExists(atPath: destinationUrl.path) {
                    try? FileManager.default.removeItem(at: destinationUrl)
                }

                try FileManager.default.moveItem(at: location, to: destinationUrl)
                self.downloadedFileUrl = destinationUrl
                self.isDownloading = false
                self.progress = 1.0

                // Inspect Codecs and Container
                let inspection = await inspectMedia(url: destinationUrl)
                self.mediaInspection = inspection

                // Smart auto-save to Camera Roll if supported
                if inspection.isPhotosCompatible {
                    let photoSuccess = await saveToPhotosLibrary(url: destinationUrl, inspection: inspection)
                    self.savedToPhotos = photoSuccess
                } else {
                    self.savedToPhotos = false
                }
            } catch {
                self.isDownloading = false
                self.errorMessage = "Failed to store downloaded file: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            if let err = error as? URLError, err.code == .cancelled {
                self.isDownloading = false
                return
            }
            if let err = error {
                self.isDownloading = false
                self.errorMessage = "Download Error: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - Inspection & Photos Routing

    private func inspectMedia(url: URL) async -> MediaInspection {
        let ext = url.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "webp", "tiff", "gif"]
        let isImage = imageExtensions.contains(ext)

        if isImage {
            var width = 0
            var height = 0
            if let img = UIImage(contentsOfFile: url.path) {
                width = Int(img.size.width)
                height = Int(img.size.height)
            }
            let isCompatible = ["jpg", "jpeg", "png", "heic"].contains(ext)
            return MediaInspection(
                isVideo: false,
                isImage: true,
                container: ext.uppercased(),
                videoCodec: ext.uppercased(),
                audioCodec: "None",
                width: width,
                height: height,
                durationSec: 0,
                isPhotosCompatible: isCompatible,
                incompatibilityReason: isCompatible ? nil : "WebP/TIFF not natively saved to Camera Roll. Stored safely in CFX Studio Files."
            )
        }

        // Video inspection
        let asset = AVURLAsset(url: url)
        var durationSec: Double = 0
        var width: Int = 0
        var height: Int = 0
        var videoCodec = "Unknown"
        var audioCodec = "None"

        if let dur = try? await asset.load(.duration) {
            durationSec = dur.seconds
        }

        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
            if let naturalSize = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
                width = Int(isPortrait ? naturalSize.height : naturalSize.width)
                height = Int(isPortrait ? naturalSize.width : naturalSize.height)
            }
            if let descs = try? await track.load(.formatDescriptions), let first = descs.first {
                let subType = CMFormatDescriptionGetMediaSubType(first)
                videoCodec = friendlyVideoCodecName(fourCharCodeToString(subType))
            }
        }

        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio), let track = audioTracks.first {
            if let descs = try? await track.load(.formatDescriptions), let first = descs.first {
                let subType = CMFormatDescriptionGetMediaSubType(first)
                audioCodec = friendlyAudioCodecName(fourCharCodeToString(subType))
            }
        }

        // Check iOS Photos compatibility
        let isStandardContainer = (ext == "mp4" || ext == "mov" || ext == "m4v")
        let isSupportedVideoCodec = videoCodec.contains("H.264") || videoCodec.contains("HEVC") || videoCodec.contains("ProRes") || videoCodec.contains("MPEG-4")
        let isSupportedAudioCodec = audioCodec.contains("AAC") || audioCodec.contains("PCM") || audioCodec.contains("None") || audioCodec.contains("ALAC")

        var incompatibilityReason: String? = nil
        let isCompatible: Bool

        if !isStandardContainer {
            isCompatible = false
            incompatibilityReason = ".\(ext.uppercased()) container is not supported by Photos. Saved to On My iPhone > CFX Studio."
        } else if !isSupportedVideoCodec {
            isCompatible = false
            incompatibilityReason = "\(videoCodec) video codec is not supported by Camera Roll. Saved to Files."
        } else if !isSupportedAudioCodec {
            isCompatible = false
            incompatibilityReason = "\(audioCodec) audio codec is not supported by Camera Roll. Saved to Files."
        } else {
            isCompatible = true
        }

        return MediaInspection(
            isVideo: true,
            isImage: false,
            container: ext.uppercased(),
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            width: width,
            height: height,
            durationSec: durationSec,
            isPhotosCompatible: isCompatible,
            incompatibilityReason: incompatibilityReason
        )
    }

    private func saveToPhotosLibrary(url: URL, inspection: MediaInspection) async -> Bool {
        let status = await requestPhotoAuthorization()
        guard status == .authorized || status == .limited else {
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if inspection.isVideo {
                    request.addResource(with: .video, fileURL: url, options: nil)
                } else {
                    request.addResource(with: .photo, fileURL: url, options: nil)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func requestPhotoAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
        return cleaned.isEmpty ? "CFX_Download_\(Int(Date().timeIntervalSince1970))" : cleaned
    }
}
