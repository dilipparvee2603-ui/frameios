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
    @Published var statusMessage: String = ""

    private var downloadTask: URLSessionDownloadTask?
    private var activeDownloadTask: Task<Void, Never>?
    private var urlSession: URLSession?
    private var lastSpeedCheckTime: Date = Date()
    private var lastSpeedBytes: Int64 = 0

    // Multi-stage / Muxing state
    private var isMuxWorkflow: Bool = false
    private var pendingAudioUrl: URL? = nil
    private var tempVideoFileUrl: URL? = nil
    private var customTargetFilename: String? = nil

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 3600.0
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func startDownload(urlString: String, customFilename: String? = nil) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            self.errorMessage = "Please enter a valid HTTP or HTTPS direct link."
            return
        }

        reset()
        self.isDownloading = true
        self.statusMessage = "Downloading Media..."
        self.customTargetFilename = customFilename
        self.lastSpeedCheckTime = Date()
        self.lastSpeedBytes = 0

        let task = urlSession?.downloadTask(with: url)
        self.downloadTask = task
        task?.resume()
    }

    func startYouTubeDownload(option: YouTubeQualityOption, videoTitle: String) {
        reset()
        self.isDownloading = true
        self.statusMessage = "Starting high-speed stream..."
        self.lastSpeedCheckTime = Date()
        self.lastSpeedBytes = 0

        let safeTitle = sanitizeFilename(videoTitle)

        activeDownloadTask = Task {
            do {
                if let audioUrlStr = option.audioUrl,
                   let audioUrl = URL(string: audioUrlStr),
                   option.format == "MP4",
                   let videoUrl = URL(string: option.downloadUrl) {

                    self.isMuxWorkflow = true
                    let tempVideo = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cfx_vid_\(UUID().uuidString).mp4")
                    let tempAudio = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cfx_aud_\(UUID().uuidString).m4a")
                    self.tempVideoFileUrl = tempVideo

                    // Stage 1: High-Speed Chunked Video Download (0% -> 85%)
                    self.statusMessage = "Downloading Video (\(option.resolution)p)..."
                    try await self.downloadChunked(from: videoUrl, to: tempVideo, baseProgress: 0.0, weight: 0.85)

                    // Stage 2: Audio Download (85% -> 95%)
                    self.statusMessage = "Downloading Audio Track (AAC)..."
                    try await self.downloadChunked(from: audioUrl, to: tempAudio, baseProgress: 0.85, weight: 0.10)

                    // Stage 3: Lossless Passthrough Mux
                    self.statusMessage = "Losslessly Merging Video & Audio..."
                    self.progress = 0.96

                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true, attributes: nil)
                    let destinationUrl = docs.appendingPathComponent("\(safeTitle) - \(option.resolution)p.mp4")

                    try await self.muxVideoAndAudio(videoUrl: tempVideo, audioUrl: tempAudio, outputUrl: destinationUrl)

                    try? FileManager.default.removeItem(at: tempVideo)
                    try? FileManager.default.removeItem(at: tempAudio)
                    self.tempVideoFileUrl = nil

                    await self.finalizeDownload(destinationUrl: destinationUrl)
                } else {
                    // Single stream (audio-only, WebM 4K, or combined)
                    self.isMuxWorkflow = false
                    let ext = option.format.lowercased()
                    let cleanLabel = option.label
                        .replacingOccurrences(of: "/", with: "-")
                        .replacingOccurrences(of: "•", with: "-")
                    let filename = "\(safeTitle) - \(cleanLabel).\(ext)"

                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true, attributes: nil)
                    let destinationUrl = docs.appendingPathComponent(sanitizeFilename(filename))

                    self.statusMessage = "Downloading \(option.label)..."
                    if let url = URL(string: option.downloadUrl) {
                        try await self.downloadChunked(from: url, to: destinationUrl, baseProgress: 0.0, weight: 1.0)
                        await self.finalizeDownload(destinationUrl: destinationUrl)
                    } else {
                        self.errorMessage = "Invalid stream URL."
                        self.isDownloading = false
                    }
                }
            } catch {
                if Task.isCancelled {
                    self.isDownloading = false
                    return
                }
                self.isDownloading = false
                self.errorMessage = "Download Error: \(error.localizedDescription)"
                self.cleanupTempFiles()
            }
        }
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        cleanupTempFiles()
        isDownloading = false
        progress = 0.0
        statusMessage = ""
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
        statusMessage = ""
        isMuxWorkflow = false
        pendingAudioUrl = nil
        tempVideoFileUrl = nil
        customTargetFilename = nil
    }

    // MARK: - High-Speed Chunked Streaming (Bypasses YouTube Throttling)

    private func downloadChunked(from url: URL, to destinationUrl: URL, baseProgress: Double, weight: Double) async throws {
        // Probe size with Range: bytes=0-0
        var probeReq = URLRequest(url: url)
        probeReq.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        probeReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        probeReq.timeoutInterval = 12.0

        let (zeroData, probeResp) = try await URLSession.shared.data(for: probeReq)
        var totalBytes: Int64 = -1

        if let http = probeResp as? HTTPURLResponse,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
            if let totalStr = contentRange.components(separatedBy: "/").last,
               let parsed = Int64(totalStr) {
                totalBytes = parsed
            }
        }

        if totalBytes <= 0 {
            totalBytes = probeResp.expectedContentLength
        }

        if FileManager.default.fileExists(atPath: destinationUrl.path) {
            try? FileManager.default.removeItem(at: destinationUrl)
        }
        FileManager.default.createFile(atPath: destinationUrl.path, contents: nil, attributes: nil)

        let fileHandle = try FileHandle(forWritingTo: destinationUrl)
        defer {
            try? fileHandle.close()
        }

        guard totalBytes > 0 else {
            var directReq = URLRequest(url: url)
            directReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: directReq)
            try fileHandle.write(contentsOf: data)
            self.bytesWritten = Int64(data.count)
            self.totalBytes = Int64(data.count)
            self.progress = baseProgress + weight
            return
        }

        try fileHandle.write(contentsOf: zeroData)
        var downloadedBytes: Int64 = Int64(zeroData.count)

        // 5MB chunks (YouTube sweet spot for full multi-megabyte burst speed)
        let chunkSize: Int64 = 5 * 1024 * 1024
        var startOffset: Int64 = downloadedBytes

        var lastSpeedTime = Date()
        var lastSpeedBytes: Int64 = downloadedBytes

        while startOffset < totalBytes {
            try Task.checkCancellation()

            let endOffset = min(totalBytes - 1, startOffset + chunkSize - 1)
            var chunkReq = URLRequest(url: url)
            chunkReq.setValue("bytes=\(startOffset)-\(endOffset)", forHTTPHeaderField: "Range")
            chunkReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            chunkReq.timeoutInterval = 30.0

            let (chunkData, _) = try await URLSession.shared.data(for: chunkReq)
            try fileHandle.write(contentsOf: chunkData)
            downloadedBytes += Int64(chunkData.count)
            startOffset = endOffset + 1

            let currentBytes = downloadedBytes
            let now = Date()
            let timeDiff = now.timeIntervalSince(lastSpeedTime)
            if timeDiff >= 0.25 {
                let speedBps = Double(currentBytes - lastSpeedBytes) / timeDiff
                self.downloadSpeedMBs = max(0.0, speedBps / (1024.0 * 1024.0))
                lastSpeedTime = now
                lastSpeedBytes = currentBytes
            }

            self.bytesWritten = currentBytes
            self.totalBytes = totalBytes
            let fraction = Double(currentBytes) / Double(max(1, totalBytes))
            self.progress = min(1.0, baseProgress + (fraction * weight))
        }
    }

    private func cleanupTempFiles() {
        if let tempVideo = tempVideoFileUrl {
            try? FileManager.default.removeItem(at: tempVideo)
            tempVideoFileUrl = nil
        }
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
                let currentFraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                if self.isMuxWorkflow {
                    if self.tempVideoFileUrl == nil {
                        // Video downloading: 0% -> 85%
                        self.progress = min(0.85, currentFraction * 0.85)
                    } else {
                        // Audio downloading: 85% -> 95%
                        self.progress = min(0.95, 0.85 + (currentFraction * 0.10))
                    }
                } else {
                    self.progress = currentFraction
                }
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
        // SYNCHRONOUS MOVE: Move the file out of CFNetwork's staging directory before this delegate method returns!
        // iOS automatically deletes the file at `location` as soon as this method returns.
        let securedTempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfx_staged_\(UUID().uuidString).tmp")

        do {
            if FileManager.default.fileExists(atPath: securedTempUrl.path) {
                try FileManager.default.removeItem(at: securedTempUrl)
            }
            try FileManager.default.moveItem(at: location, to: securedTempUrl)
        } catch {
            Task { @MainActor in
                self.isDownloading = false
                self.errorMessage = "Failed to secure downloaded file: \(error.localizedDescription)"
            }
            return
        }

        let suggestedName = downloadTask.response?.suggestedFilename
        let fallbackName = downloadTask.originalRequest?.url?.lastPathComponent
        let responseMimeType = downloadTask.response?.mimeType

        Task { @MainActor in
            do {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true, attributes: nil)

                if self.isMuxWorkflow {
                    if self.tempVideoFileUrl == nil {
                        // Stage 1 Complete: Video track downloaded
                        let tempVideo = FileManager.default.temporaryDirectory
                            .appendingPathComponent("cfx_vid_\(UUID().uuidString).mp4")
                        if FileManager.default.fileExists(atPath: tempVideo.path) {
                            try? FileManager.default.removeItem(at: tempVideo)
                        }
                        try FileManager.default.moveItem(at: securedTempUrl, to: tempVideo)
                        self.tempVideoFileUrl = tempVideo

                        // Stage 2: Start downloading audio track
                        if let audioUrl = self.pendingAudioUrl {
                            self.statusMessage = "Downloading Audio Track (AAC)..."
                            self.lastSpeedCheckTime = Date()
                            self.lastSpeedBytes = 0
                            let audioTask = self.urlSession?.downloadTask(with: audioUrl)
                            self.downloadTask = audioTask
                            audioTask?.resume()
                            return
                        }
                    } else if let tempVideo = self.tempVideoFileUrl {
                        // Stage 2 Complete: Audio track downloaded
                        let tempAudio = FileManager.default.temporaryDirectory
                            .appendingPathComponent("cfx_aud_\(UUID().uuidString).m4a")
                        if FileManager.default.fileExists(atPath: tempAudio.path) {
                            try? FileManager.default.removeItem(at: tempAudio)
                        }
                        try FileManager.default.moveItem(at: securedTempUrl, to: tempAudio)

                        self.statusMessage = "Losslessly Merging Video & Audio..."
                        self.progress = 0.96

                        let filename = self.customTargetFilename ?? "CFX_YouTube_\(Int(Date().timeIntervalSince1970)).mp4"
                        let destinationUrl = docs.appendingPathComponent(self.sanitizeFilename(filename))

                        // Stage 3: AVMutableComposition Passthrough Mux
                        do {
                            try await self.muxVideoAndAudio(videoUrl: tempVideo, audioUrl: tempAudio, outputUrl: destinationUrl)
                            try? FileManager.default.removeItem(at: tempVideo)
                            try? FileManager.default.removeItem(at: tempAudio)
                            self.tempVideoFileUrl = nil
                            self.pendingAudioUrl = nil

                            await self.finalizeDownload(destinationUrl: destinationUrl)
                            return
                        } catch {
                            // Fallback if muxing fails: keep video track directly
                            if FileManager.default.fileExists(atPath: destinationUrl.path) {
                                try? FileManager.default.removeItem(at: destinationUrl)
                            }
                            try FileManager.default.moveItem(at: tempVideo, to: destinationUrl)
                            try? FileManager.default.removeItem(at: tempAudio)
                            self.tempVideoFileUrl = nil
                            self.pendingAudioUrl = nil

                            await self.finalizeDownload(destinationUrl: destinationUrl)
                            return
                        }
                    }
                }

                // Standard direct single-file download
                let originalName = self.customTargetFilename
                    ?? suggestedName
                    ?? fallbackName
                    ?? "CFX_Download_\(Int(Date().timeIntervalSince1970))"

                var safeFilename = self.sanitizeFilename(originalName)
                if !safeFilename.contains(".") {
                    if let mime = responseMimeType?.lowercased() {
                        if mime.contains("mp4") { safeFilename += ".mp4" }
                        else if mime.contains("quicktime") || mime.contains("mov") { safeFilename += ".mov" }
                        else if mime.contains("webm") { safeFilename += ".webm" }
                        else if mime.contains("jpeg") || mime.contains("jpg") { safeFilename += ".jpg" }
                        else if mime.contains("png") { safeFilename += ".png" }
                        else if mime.contains("heic") { safeFilename += ".heic" }
                        else if mime.contains("m4a") || mime.contains("audio/mp4") { safeFilename += ".m4a" }
                        else if mime.contains("audio/mpeg") || mime.contains("mp3") { safeFilename += ".mp3" }
                    } else {
                        safeFilename += ".mp4"
                    }
                }

                let destinationUrl = docs.appendingPathComponent(safeFilename)

                if FileManager.default.fileExists(atPath: destinationUrl.path) {
                    try? FileManager.default.removeItem(at: destinationUrl)
                }

                try FileManager.default.moveItem(at: securedTempUrl, to: destinationUrl)
                await self.finalizeDownload(destinationUrl: destinationUrl)
            } catch {
                try? FileManager.default.removeItem(at: securedTempUrl)
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
                self.cleanupTempFiles()
            }
        }
    }

    // MARK: - Lossless Muxer

    private func muxVideoAndAudio(videoUrl: URL, audioUrl: URL, outputUrl: URL) async throws {
        let videoAsset = AVURLAsset(url: videoUrl)
        let audioAsset = AVURLAsset(url: audioUrl)

        let composition = AVMutableComposition()

        // 1. Video track
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "CFXMuxer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found in stream."])
        }

        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "CFXMuxer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create video track in composition."])
        }

        let videoDuration = try await videoAsset.load(.duration)
        let videoRange = CMTimeRange(start: .zero, duration: videoDuration)
        try compVideoTrack.insertTimeRange(videoRange, of: videoTrack, at: .zero)

        if let transform = try? await videoTrack.load(.preferredTransform) {
            compVideoTrack.preferredTransform = transform
        }

        // 2. Audio track
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first,
           let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            let durationSeconds = min(videoDuration.seconds, audioDuration.seconds)
            let clampedDuration = CMTime(seconds: durationSeconds, preferredTimescale: 600)
            let audioRange = CMTimeRange(start: .zero, duration: clampedDuration)
            try? compAudioTrack.insertTimeRange(audioRange, of: audioTrack, at: .zero)
        }

        // 3. Lossless Passthrough Export Session
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "CFXMuxer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Passthrough export session unavailable."])
        }

        if FileManager.default.fileExists(atPath: outputUrl.path) {
            try? FileManager.default.removeItem(at: outputUrl)
        }

        export.outputURL = outputUrl
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        await export.export()

        if let err = export.error {
            throw err
        }
        if export.status != .completed {
            throw NSError(domain: "CFXMuxer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export ended with status: \(export.status.rawValue)"])
        }
    }

    private func finalizeDownload(destinationUrl: URL) async {
        self.downloadedFileUrl = destinationUrl
        self.isDownloading = false
        self.progress = 1.0
        self.statusMessage = "Download Complete"

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
            .replacingOccurrences(of: "*", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "<", with: "_")
            .replacingOccurrences(of: ">", with: "_")
            .replacingOccurrences(of: "|", with: "_")
        return cleaned.isEmpty ? "CFX_Download_\(Int(Date().timeIntervalSince1970))" : cleaned
    }
}
