import Foundation
import UIKit
import Combine

// MARK: - TikTok Models
enum TikTokMediaType: String, CaseIterable, Identifiable, Codable {
    case video = "HD Video (No Watermark)"
    case audio = "Original Sound / Music (MP3)"
    case photo = "Photo Slide"

    var id: String { rawValue }

    var systemIcon: String {
        switch self {
        case .video: return "play.circle.fill"
        case .audio: return "music.note"
        case .photo: return "photo.fill"
        }
    }
}

struct TikTokMediaItem: Identifiable, Hashable {
    let id: String
    let type: TikTokMediaType
    let downloadUrl: String
    let thumbnailUrl: String?
    let filename: String
    let displayLabel: String
}

struct TikTokPostInfo {
    let originalUrl: String
    let authorName: String
    let authorHandle: String
    let caption: String
    let musicTitle: String?
    let thumbnailUrl: String?
    let items: [TikTokMediaItem]
}

// MARK: - TikTok Download Engine
@MainActor
final class TikTokDownloadEngine: ObservableObject {
    @Published var isFetching: Bool = false
    @Published var postInfo: TikTokPostInfo? = nil
    @Published var errorMessage: String? = nil

    // Multi-download batch state
    @Published var isBatchDownloading: Bool = false
    @Published var batchCurrentIndex: Int = 0
    @Published var batchTotalCount: Int = 0
    @Published var batchStatusMessage: String = ""

    // Cobalt Fallback Instances
    private let cobaltInstances = [
        "https://api.cobalt.tools/",
        "https://cobalt-api.kwiatekm.tokyo/",
        "https://api.wuk.sh/",
        "https://co.vial.canary.is/",
        "https://instances.hyper.lol/"
    ]

    // MARK: - URL Utilities
    static func isTikTokUrl(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("tiktok.com") ||
              trimmed.contains("douyin.com") else {
            return false
        }
        return trimmed.contains("/video/") ||
               trimmed.contains("/photo/") ||
               trimmed.contains("vm.tiktok.com") ||
               trimmed.contains("vt.tiktok.com") ||
               trimmed.contains("/v/") ||
               trimmed.contains("/t/")
    }

    static func cleanTikTokUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return urlString
        }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        return comps?.url?.absoluteString ?? urlString
    }

    // MARK: - Primary Fetch Pipeline
    func fetchMedia(for rawUrl: String) async {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isTikTokUrl(trimmed) else {
            self.errorMessage = "Please enter a valid TikTok video or photo link."
            return
        }

        self.isFetching = true
        self.errorMessage = nil
        self.postInfo = nil
        AppLogger.shared.log(tag: "TIKTOK", message: "Fetching media for: \(trimmed)", isError: false)

        // 1. Resolve shortlinks (vm.tiktok.com, vt.tiktok.com)
        var targetUrl = trimmed
        if trimmed.contains("vm.tiktok.com") || trimmed.contains("vt.tiktok.com") || trimmed.contains("/t/") {
            if let resolved = await resolveRedirects(for: trimmed) {
                targetUrl = resolved
                AppLogger.shared.log(tag: "TIKTOK", message: "Resolved shortlink to: \(targetUrl)", isError: false)
            }
        }

        let cleaned = Self.cleanTikTokUrl(targetUrl)

        // 2. Cascade Attempt 1: TikWM Public API
        if let info = await fetchViaTikWM(url: cleaned.isEmpty ? targetUrl : cleaned) {
            self.postInfo = info
            self.isFetching = false
            AppLogger.shared.log(tag: "TIKTOK", message: "Extracted \(info.items.count) media items via TikWM API", isError: false)
            return
        }

        // 3. Cascade Attempt 2: Cobalt Instances
        if let info = await fetchViaCobalt(url: targetUrl) {
            self.postInfo = info
            self.isFetching = false
            AppLogger.shared.log(tag: "TIKTOK", message: "Extracted TikTok media via Cobalt fallback", isError: false)
            return
        }

        self.isFetching = false
        self.errorMessage = "Could not extract media from this TikTok post. Please verify the link is public and accessible."
        AppLogger.shared.log(tag: "TIKTOK", message: "Extraction failed for URL: \(targetUrl)", isError: true)
    }

    // MARK: - Method 1: TikWM API
    private func fetchViaTikWM(url: String) async -> TikTokPostInfo? {
        guard let encodedUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiUrl = URL(string: "https://www.tikwm.com/api/?url=\(encodedUrl)&hd=1") else {
            return nil
        }

        var request = URLRequest(url: apiUrl)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.tikwm.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = root["code"] as? Int, code == 0,
                  let dataDict = root["data"] as? [String: Any] else {
                return nil
            }

            let videoId = dataDict["id"] as? String ?? UUID().uuidString.prefix(8).lowercased()
            let title = dataDict["title"] as? String ?? ""
            let cover = dataDict["cover"] as? String

            let authorObj = dataDict["author"] as? [String: Any]
            let authorHandle = "@" + (authorObj?["unique_id"] as? String ?? "tiktok_user")
            let authorName = authorObj?["nickname"] as? String ?? authorHandle

            let musicInfo = dataDict["music_info"] as? [String: Any]
            let musicTitle = musicInfo?["title"] as? String

            var items: [TikTokMediaItem] = []

            // Check if it's a photo slideshow
            if let images = dataDict["images"] as? [String], !images.isEmpty {
                for (idx, imgUrl) in images.enumerated() {
                    let absoluteImg = imgUrl.hasPrefix("http") ? imgUrl : "https://www.tikwm.com\(imgUrl)"
                    items.append(TikTokMediaItem(
                        id: "\(videoId)_img_\(idx)",
                        type: .photo,
                        downloadUrl: absoluteImg,
                        thumbnailUrl: absoluteImg,
                        filename: "CFX_TikTok_Slide_\(videoId)_\(idx + 1).jpg",
                        displayLabel: "Slide Photo \(idx + 1)"
                    ))
                }
            } else {
                // Video: prefer hdplay, fallback to play
                let rawVideoUrl = (dataDict["hdplay"] as? String) ?? (dataDict["play"] as? String)
                if let rawVideoUrl = rawVideoUrl, !rawVideoUrl.isEmpty {
                    let videoUrl = rawVideoUrl.hasPrefix("http") ? rawVideoUrl : "https://www.tikwm.com\(rawVideoUrl)"
                    items.append(TikTokMediaItem(
                        id: "\(videoId)_video",
                        type: .video,
                        downloadUrl: videoUrl,
                        thumbnailUrl: cover,
                        filename: "CFX_TikTok_\(videoId).mp4",
                        displayLabel: "Watermark-Free HD Video (MP4)"
                    ))
                }
            }

            // Audio track (MP3)
            if let rawMusicUrl = dataDict["music"] as? String, !rawMusicUrl.isEmpty {
                let musicUrl = rawMusicUrl.hasPrefix("http") ? rawMusicUrl : "https://www.tikwm.com\(rawMusicUrl)"
                let audioLabel = musicTitle != nil ? "Audio: \(musicTitle!)" : "Background Music (MP3)"
                items.append(TikTokMediaItem(
                    id: "\(videoId)_audio",
                    type: .audio,
                    downloadUrl: musicUrl,
                    thumbnailUrl: cover,
                    filename: "CFX_TikTok_Audio_\(videoId).mp3",
                    displayLabel: audioLabel
                ))
            }

            guard !items.isEmpty else { return nil }

            return TikTokPostInfo(
                originalUrl: url,
                authorName: authorName,
                authorHandle: authorHandle,
                caption: title,
                musicTitle: musicTitle,
                thumbnailUrl: cover,
                items: items
            )
        } catch {
            return nil
        }
    }

    // MARK: - Method 2: Cobalt Fallback
    private func fetchViaCobalt(url: String) async -> TikTokPostInfo? {
        for instance in cobaltInstances {
            guard let endpoint = URL(string: instance) else { continue }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 12.0

            let payload: [String: Any] = [
                "url": url,
                "videoQuality": "max"
            ]

            guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            request.httpBody = httpBody

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (httpResponse.statusCode == 200 || httpResponse.statusCode == 201) else {
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let status = json["status"] as? String ?? ""

                if (status == "redirect" || status == "tunnel" || status == "stream"),
                   let downloadUrl = json["url"] as? String, !downloadUrl.isEmpty {
                    let randId = UUID().uuidString.prefix(8).lowercased()
                    let item = TikTokMediaItem(
                        id: "\(randId)_cobalt",
                        type: .video,
                        downloadUrl: downloadUrl,
                        thumbnailUrl: nil,
                        filename: "CFX_TikTok_\(randId).mp4",
                        displayLabel: "Watermark-Free Video (MP4)"
                    )

                    return TikTokPostInfo(
                        originalUrl: url,
                        authorName: "TikTok Creator",
                        authorHandle: "@tiktok",
                        caption: "TikTok Video extracted via Cobalt",
                        musicTitle: nil,
                        thumbnailUrl: nil,
                        items: [item]
                    )
                }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Resolve Shortlinks
    private func resolveRedirects(for urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, let finalUrl = httpResponse.url {
                return finalUrl.absoluteString
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - Batch Downloader
    func downloadAllItems(items: [TikTokMediaItem], with downloadEngine: DirectDownloadEngine) async {
        guard !items.isEmpty else { return }

        self.isBatchDownloading = true
        self.batchTotalCount = items.count
        self.batchCurrentIndex = 0

        for (idx, item) in items.enumerated() {
            self.batchCurrentIndex = idx + 1
            self.batchStatusMessage = "Saving Slide \(idx + 1) of \(items.count)..."

            guard let url = URL(string: item.downloadUrl) else { continue }

            do {
                let (tempUrl, _) = try await URLSession.shared.download(from: url)
                let ext = item.type == .photo ? "jpg" : (item.type == .audio ? "mp3" : "mp4")
                let targetFilename = "CFX_TikTok_Item_\(idx + 1)_\(UUID().uuidString.prefix(6)).\(ext)"
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let localUrl = docs.appendingPathComponent(targetFilename)

                try? FileManager.default.removeItem(at: localUrl)
                try FileManager.default.moveItem(at: tempUrl, to: localUrl)

                if item.type == .photo {
                    _ = await downloadEngine.saveImageToPhotos(url: localUrl)
                } else if item.type == .video {
                    _ = await downloadEngine.saveVideoToPhotos(url: localUrl)
                }

                try? FileManager.default.removeItem(at: localUrl)
            } catch {
                AppLogger.shared.log(tag: "TIKTOK", message: "Batch save error on item \(idx + 1): \(error.localizedDescription)", isError: true)
            }
        }

        self.isBatchDownloading = false
        self.batchStatusMessage = "Saved all \(items.count) items to Camera Roll!"
        NotificationManager.shared.notifyBatchDownloadCompleted(count: items.count, platform: "TikTok")
        AppLogger.shared.log(tag: "TIKTOK", message: "Saved all \(items.count) items to Photos", isError: false)
    }
}
