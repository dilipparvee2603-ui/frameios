import Foundation
import UIKit
import Combine

// MARK: - Twitter / X Models
enum TwitterMediaType: String, CaseIterable, Identifiable, Codable {
    case video = "Video (MP4)"
    case gif = "GIF Animation"
    case photo = "Photo (JPEG)"

    var id: String { rawValue }

    var systemIcon: String {
        switch self {
        case .video: return "play.circle.fill"
        case .gif: return "arrow.triangle.2.circlepath.circle.fill"
        case .photo: return "photo.fill"
        }
    }
}

struct TwitterMediaItem: Identifiable, Hashable {
    let id: String
    let type: TwitterMediaType
    let downloadUrl: String
    let thumbnailUrl: String?
    let filename: String
    let width: Int?
    let height: Int?
    let displayLabel: String
}

struct TweetInfo {
    let originalUrl: String
    let tweetId: String
    let authorName: String
    let authorHandle: String
    let text: String
    let likes: Int?
    let retweets: Int?
    let items: [TwitterMediaItem]
}

// MARK: - Twitter / X Download Engine
@MainActor
final class TwitterDownloadEngine: ObservableObject {
    @Published var isFetching: Bool = false
    @Published var tweetInfo: TweetInfo? = nil
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
    static func isTwitterUrl(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("twitter.com") ||
              trimmed.contains("x.com") ||
              trimmed.contains("t.co") ||
              trimmed.contains("vxtwitter.com") ||
              trimmed.contains("fxtwitter.com") else {
            return false
        }
        return trimmed.contains("/status/") || trimmed.contains("t.co/")
    }

    static func cleanTwitterUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return urlString
        }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        return comps?.url?.absoluteString ?? urlString
    }

    static func extractTweetId(from urlString: String) -> String? {
        let pattern = #"(?:status|statuses)\/([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let idRange = Range(match.range(at: 1), in: urlString) else {
            return nil
        }
        return String(urlString[idRange])
    }

    // MARK: - Primary Fetch Pipeline
    func fetchMedia(for rawUrl: String) async {
        let cleaned = Self.cleanTwitterUrl(rawUrl)
        guard Self.isTwitterUrl(cleaned) else {
            self.errorMessage = "Please enter a valid Twitter / X status URL."
            return
        }

        self.isFetching = true
        self.errorMessage = nil
        self.tweetInfo = nil
        AppLogger.shared.log(tag: "TWITTER", message: "Fetching media for: \(cleaned)", isError: false)

        // 1. Resolve shortlink if needed (e.g. t.co)
        var resolvedUrlString = cleaned
        if cleaned.contains("t.co") {
            if let resolved = await resolveShortLink(url: cleaned) {
                resolvedUrlString = resolved
            }
        }

        guard let tweetId = Self.extractTweetId(from: resolvedUrlString) else {
            self.errorMessage = "Could not extract Tweet ID from URL."
            self.isFetching = false
            return
        }

        // 2. Cascade Attempt 1: VxTwitter API
        if let info = await fetchViaVxTwitter(tweetId: tweetId, originalUrl: resolvedUrlString) {
            self.tweetInfo = info
            self.isFetching = false
            AppLogger.shared.log(tag: "TWITTER", message: "Extracted \(info.items.count) items via VxTwitter API", isError: false)
            return
        }

        // 3. Cascade Attempt 2: FxTwitter API
        if let info = await fetchViaFxTwitter(tweetId: tweetId, originalUrl: resolvedUrlString) {
            self.tweetInfo = info
            self.isFetching = false
            AppLogger.shared.log(tag: "TWITTER", message: "Extracted \(info.items.count) items via FxTwitter API", isError: false)
            return
        }

        // 4. Cascade Attempt 3: Cobalt Instances
        if let info = await fetchViaCobalt(url: resolvedUrlString, tweetId: tweetId) {
            self.tweetInfo = info
            self.isFetching = false
            AppLogger.shared.log(tag: "TWITTER", message: "Extracted video via Cobalt fallback", isError: false)
            return
        }

        self.isFetching = false
        self.errorMessage = "Could not extract media from this Tweet. The post may be private, text-only, or media may have expired."
        AppLogger.shared.log(tag: "TWITTER", message: "Extraction failed for Tweet ID: \(tweetId)", isError: true)
    }

    // MARK: - Method 1: VxTwitter API
    private func fetchViaVxTwitter(tweetId: String, originalUrl: String) async -> TweetInfo? {
        guard let url = URL(string: "https://api.vxtwitter.com/i/status/\(tweetId)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("CFXFrameStudio/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let authorName = json["user_name"] as? String ?? "Twitter User"
            let authorHandle = "@" + (json["user_screen_name"] as? String ?? "user")
            let text = json["text"] as? String ?? ""
            let likes = json["likes"] as? Int
            let retweets = json["retweets"] as? Int

            var items: [TwitterMediaItem] = []

            // Check media_extended
            if let mediaExtended = json["media_extended"] as? [[String: Any]], !mediaExtended.isEmpty {
                for (idx, m) in mediaExtended.enumerated() {
                    let typeStr = m["type"] as? String ?? ""
                    guard let mediaUrl = m["url"] as? String, !mediaUrl.isEmpty else { continue }
                    let thumbUrl = m["thumbnail_url"] as? String

                    let mType: TwitterMediaType
                    let ext: String
                    if typeStr == "video" {
                        mType = .video
                        ext = "mp4"
                    } else if typeStr == "gif" {
                        mType = .gif
                        ext = "mp4"
                    } else {
                        mType = .photo
                        ext = "jpg"
                    }

                    let label = mType == .video ? "Video \(idx + 1) (HD MP4)" : (mType == .gif ? "Animated GIF (MP4)" : "Photo \(idx + 1)")
                    let filename = "CFX_X_\(tweetId)_\(idx + 1).\(ext)"

                    items.append(TwitterMediaItem(
                        id: "\(tweetId)_\(idx)",
                        type: mType,
                        downloadUrl: mediaUrl,
                        thumbnailUrl: thumbUrl ?? (mType == .photo ? mediaUrl : nil),
                        filename: filename,
                        width: m["size"] as? [String: Any]? ?? nil != nil ? (m["size"] as? [String: Any])?["width"] as? Int : nil,
                        height: m["size"] as? [String: Any]? ?? nil != nil ? (m["size"] as? [String: Any])?["height"] as? Int : nil,
                        displayLabel: label
                    ))
                }
            }

            // Fallback to mediaURLs if media_extended was empty
            if items.isEmpty, let mediaUrls = json["mediaURLs"] as? [String], !mediaUrls.isEmpty {
                for (idx, mediaUrl) in mediaUrls.enumerated() {
                    let isVid = mediaUrl.lowercased().contains(".mp4") || mediaUrl.lowercased().contains("video.twimg.com")
                    let mType: TwitterMediaType = isVid ? .video : .photo
                    let ext = isVid ? "mp4" : "jpg"
                    let label = isVid ? "Video \(idx + 1) (HD MP4)" : "Photo \(idx + 1)"
                    let filename = "CFX_X_\(tweetId)_\(idx + 1).\(ext)"

                    items.append(TwitterMediaItem(
                        id: "\(tweetId)_\(idx)",
                        type: mType,
                        downloadUrl: mediaUrl,
                        thumbnailUrl: isVid ? nil : mediaUrl,
                        filename: filename,
                        width: nil,
                        height: nil,
                        displayLabel: label
                    ))
                }
            }

            guard !items.isEmpty else { return nil }

            return TweetInfo(
                originalUrl: originalUrl,
                tweetId: tweetId,
                authorName: authorName,
                authorHandle: authorHandle,
                text: text,
                likes: likes,
                retweets: retweets,
                items: items
            )
        } catch {
            return nil
        }
    }

    // MARK: - Method 2: FxTwitter API
    private func fetchViaFxTwitter(tweetId: String, originalUrl: String) async -> TweetInfo? {
        guard let url = URL(string: "https://api.fxtwitter.com/i/status/\(tweetId)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("CFXFrameStudio/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tweet = root["tweet"] as? [String: Any] else {
                return nil
            }

            let authorObj = tweet["author"] as? [String: Any]
            let authorName = authorObj?["name"] as? String ?? "Twitter User"
            let authorHandle = "@" + (authorObj?["screen_name"] as? String ?? "user")
            let text = tweet["text"] as? String ?? ""
            let likes = tweet["likes"] as? Int
            let retweets = tweet["retweets"] as? Int

            var items: [TwitterMediaItem] = []

            if let mediaObj = tweet["media"] as? [String: Any] {
                // Videos
                if let videos = mediaObj["videos"] as? [[String: Any]] {
                    for (idx, vid) in videos.enumerated() {
                        guard let vUrl = vid["url"] as? String, !vUrl.isEmpty else { continue }
                        let thumb = vid["thumbnail_url"] as? String
                        items.append(TwitterMediaItem(
                            id: "\(tweetId)_v\(idx)",
                            type: .video,
                            downloadUrl: vUrl,
                            thumbnailUrl: thumb,
                            filename: "CFX_X_\(tweetId)_vid_\(idx + 1).mp4",
                            width: vid["width"] as? Int,
                            height: vid["height"] as? Int,
                            displayLabel: "HD Video \(idx + 1)"
                        ))
                    }
                }

                // Photos
                if let photos = mediaObj["photos"] as? [[String: Any]] {
                    for (idx, photo) in photos.enumerated() {
                        guard let pUrl = photo["url"] as? String, !pUrl.isEmpty else { continue }
                        items.append(TwitterMediaItem(
                            id: "\(tweetId)_p\(idx)",
                            type: .photo,
                            downloadUrl: pUrl,
                            thumbnailUrl: pUrl,
                            filename: "CFX_X_\(tweetId)_photo_\(idx + 1).jpg",
                            width: photo["width"] as? Int,
                            height: photo["height"] as? Int,
                            displayLabel: "Photo \(idx + 1)"
                        ))
                    }
                }
            }

            guard !items.isEmpty else { return nil }

            return TweetInfo(
                originalUrl: originalUrl,
                tweetId: tweetId,
                authorName: authorName,
                authorHandle: authorHandle,
                text: text,
                likes: likes,
                retweets: retweets,
                items: items
            )
        } catch {
            return nil
        }
    }

    // MARK: - Method 3: Cobalt Fallback
    private func fetchViaCobalt(url: String, tweetId: String) async -> TweetInfo? {
        for instance in cobaltInstances {
            guard let endpoint = URL(string: instance) else { continue }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10.0

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
                    let item = TwitterMediaItem(
                        id: "\(tweetId)_cobalt",
                        type: .video,
                        downloadUrl: downloadUrl,
                        thumbnailUrl: nil,
                        filename: "CFX_X_\(tweetId).mp4",
                        width: nil,
                        height: nil,
                        displayLabel: "HD Video"
                    )

                    return TweetInfo(
                        originalUrl: url,
                        tweetId: tweetId,
                        authorName: "Twitter / X User",
                        authorHandle: "@twitter",
                        text: "X Media extracted via Cobalt",
                        likes: nil,
                        retweets: nil,
                        items: [item]
                    )
                }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Shortlink Resolution
    private func resolveShortLink(url: String) async -> String? {
        guard let initialUrl = URL(string: url) else { return nil }
        var request = URLRequest(url: initialUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 8.0

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
    func downloadAllItems(items: [TwitterMediaItem], with downloadEngine: DirectDownloadEngine) async {
        guard !items.isEmpty else { return }

        self.isBatchDownloading = true
        self.batchTotalCount = items.count
        self.batchCurrentIndex = 0

        for (idx, item) in items.enumerated() {
            self.batchCurrentIndex = idx + 1
            self.batchStatusMessage = "Saving Item \(idx + 1) of \(items.count) to Photos..."

            guard let url = URL(string: item.downloadUrl) else { continue }

            do {
                let (tempUrl, _) = try await URLSession.shared.download(from: url)
                let ext = item.type == .photo ? "jpg" : "mp4"
                let targetFilename = "CFX_X_Item_\(idx + 1)_\(UUID().uuidString.prefix(6)).\(ext)"
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let localUrl = docs.appendingPathComponent(targetFilename)

                try? FileManager.default.removeItem(at: localUrl)
                try FileManager.default.moveItem(at: tempUrl, to: localUrl)

                if item.type == .photo {
                    _ = await downloadEngine.saveImageToPhotos(url: localUrl)
                } else {
                    _ = await downloadEngine.saveVideoToPhotos(url: localUrl)
                }

                try? FileManager.default.removeItem(at: localUrl)
            } catch {
                AppLogger.shared.log(tag: "TWITTER", message: "Batch save error on item \(idx + 1): \(error.localizedDescription)", isError: true)
            }
        }

        self.isBatchDownloading = false
        self.batchStatusMessage = "All \(items.count) items saved to Camera Roll!"
        AppLogger.shared.log(tag: "TWITTER", message: "Saved all \(items.count) items to Photos", isError: false)
    }
}
