import Foundation
import UIKit
import Combine

// MARK: - Instagram Models
enum InstagramMediaType: String, CaseIterable, Identifiable, Codable {
    case video = "Video / Reel"
    case photo = "Photo"

    var id: String { rawValue }

    var systemIcon: String {
        switch self {
        case .video: return "play.circle.fill"
        case .photo: return "photo.fill"
        }
    }
}

struct InstagramMediaItem: Identifiable, Hashable {
    let id: String
    let type: InstagramMediaType
    let downloadUrl: String
    let thumbnailUrl: String?
    let filename: String
    let width: Int?
    let height: Int?
    let displayLabel: String
}

enum InstagramPostKind: String {
    case reel = "Instagram Reel"
    case post = "Instagram Post"
    case carousel = "Carousel (Multi-Item)"
    case story = "Instagram Story"

    var badgeIcon: String {
        switch self {
        case .reel: return "play.square.stack.fill"
        case .post: return "photo.stack.fill"
        case .carousel: return "square.stack.3d.forward.dottedline"
        case .story: return "clock.arrow.circlepath"
        }
    }
}

struct InstagramPostInfo {
    let originalUrl: String
    let kind: InstagramPostKind
    let author: String
    let caption: String
    let thumbnailUrl: String?
    let items: [InstagramMediaItem]
}

// MARK: - Instagram Download Engine
@MainActor
final class InstagramDownloadEngine: ObservableObject {
    @Published var isFetching: Bool = false
    @Published var postInfo: InstagramPostInfo? = nil
    @Published var errorMessage: String? = nil
    @Published var customApiEndpoint: String = ""

    // Multi-download batch state
    @Published var isBatchDownloading: Bool = false
    @Published var batchCurrentIndex: Int = 0
    @Published var batchTotalCount: Int = 0
    @Published var batchStatusMessage: String = ""

    // Cobalt Fallback Instances for Carousels & Stories
    private let cobaltInstances = [
        "https://api.cobalt.tools/",
        "https://cobalt-api.kwiatekm.tokyo/",
        "https://api.wuk.sh/",
        "https://co.vial.canary.is/",
        "https://instances.hyper.lol/"
    ]

    // MARK: - URL Utilities
    static func isInstagramUrl(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("instagram.com") || trimmed.contains("instagr.am") else { return false }
        return trimmed.contains("/reel") ||
               trimmed.contains("/p/") ||
               trimmed.contains("/tv/") ||
               trimmed.contains("/stories/") ||
               trimmed.contains("/story/") ||
               trimmed.contains("/share/")
    }

    static func cleanInstagramUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return urlString
        }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        return comps?.url?.absoluteString ?? urlString
    }

    static func identifyKind(from urlString: String) -> InstagramPostKind {
        let lower = urlString.lowercased()
        if lower.contains("/stories/") || lower.contains("/story/") {
            return .story
        } else if lower.contains("/reel") {
            return .reel
        } else {
            return .post
        }
    }

    static func extractShortcode(from urlString: String) -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return UUID().uuidString.prefix(8).lowercased()
        }
        let path = url.path
        if path.contains("/reel/") {
            let code = path.components(separatedBy: "/reel/").last?.components(separatedBy: "/").first
            if let c = code, !c.isEmpty { return c }
        }
        if path.contains("/reels/") {
            let code = path.components(separatedBy: "/reels/").last?.components(separatedBy: "/").first
            if let c = code, !c.isEmpty { return c }
        }
        if path.contains("/p/") {
            let code = path.components(separatedBy: "/p/").last?.components(separatedBy: "/").first
            if let c = code, !c.isEmpty { return c }
        }
        if path.contains("/tv/") {
            let code = path.components(separatedBy: "/tv/").last?.components(separatedBy: "/").first
            if let c = code, !c.isEmpty { return c }
        }
        if path.contains("/stories/") || path.contains("/story/") {
            let segments = path.components(separatedBy: "/").filter { !$0.isEmpty }
            if let last = segments.last, !last.isEmpty {
                return last
            }
        }
        return UUID().uuidString.prefix(8).lowercased()
    }

    // MARK: - Main Fetch Entrypoint
    func fetchMedia(for rawUrl: String) async {
        let cleanedUrl = Self.cleanInstagramUrl(rawUrl)
        let shortcode = Self.extractShortcode(from: cleanedUrl)
        let initialKind = Self.identifyKind(from: cleanedUrl)

        self.isFetching = true
        self.errorMessage = nil
        self.postInfo = nil

        AppLogger.shared.log("Analyzing Instagram URL [\(initialKind.rawValue)]: \(cleanedUrl)", category: .system, level: .info)

        // 1. Direct Meta-Crawler Ingestion (High-Speed Direct Native Extraction)
        if let metaResult = await fetchViaMetaCrawler(url: cleanedUrl, shortcode: shortcode, defaultKind: initialKind) {
            self.postInfo = metaResult
            self.isFetching = false
            AppLogger.shared.log("Successfully extracted Instagram media via Meta Crawler (\(metaResult.items.count) item(s))", category: .system, level: .info)
            return
        }

        // 2. Cobalt API / Custom Instance (Handles Carousels and Stories)
        if let cobaltResult = await fetchViaCobalt(url: cleanedUrl, shortcode: shortcode, defaultKind: initialKind) {
            self.postInfo = cobaltResult
            self.isFetching = false
            AppLogger.shared.log("Successfully extracted Instagram media via Cobalt (\(cobaltResult.items.count) item(s))", category: .system, level: .info)
            return
        }

        // 3. Instagram Public Embed Fallback
        if let embedResult = await fetchViaEmbed(shortcode: shortcode, defaultKind: initialKind) {
            self.postInfo = embedResult
            self.isFetching = false
            AppLogger.shared.log("Extracted media via Instagram embed fallback", category: .system, level: .info)
            return
        }

        self.errorMessage = "Could not extract media from this Instagram link. The post or account might be private or restricted."
        AppLogger.shared.log("Failed to extract Instagram link: \(cleanedUrl)", category: .system, level: .error)
        self.isFetching = false
    }

    // MARK: - Strategy 1: Meta-Crawler Direct Ingestion
    private func fetchViaMetaCrawler(url: String, shortcode: String, defaultKind: InstagramPostKind) async -> InstagramPostInfo? {
        guard let reqUrl = URL(string: url) else { return nil }

        var request = URLRequest(url: reqUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 12.0
        // Meta's official crawler user agent ensures Instagram serves the server-rendered page with direct CDN URLs
        request.setValue("facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) else { return nil }

            // Extract Caption and Author from og:title
            var author = "Instagram Creator"
            var caption = ""
            if let titleMatch = html.extractRegex(pattern: #"<meta[^>]+property=['"]og:title['"][^>]+content=['"]([^'"]+)['"]"#) {
                let unescapedTitle = titleMatch.htmlUnescaped()
                if unescapedTitle.contains(" on Instagram: ") {
                    let parts = unescapedTitle.components(separatedBy: " on Instagram: ")
                    author = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    caption = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) : ""
                } else {
                    caption = unescapedTitle
                }
            }

            // Extract Thumbnail from og:image
            var thumbnailUrl: String? = nil
            if let ogImage = html.extractRegex(pattern: #"<meta[^>]+property=['"]og:image['"][^>]+content=['"]([^'"]+)['"]"#) {
                thumbnailUrl = ogImage.htmlUnescaped()
            }

            // Extract High-Def Video Stream from BaseURL or mp4 regex
            var videoUrls: [String] = []
            let baseURLMatches = html.extractAllRegex(pattern: #"<BaseURL>([^<]+)</BaseURL>"#)
            for m in baseURLMatches {
                var clean = m.htmlUnescaped()
                if clean.contains(".mp4") {
                    clean = clean.components(separatedBy: "\\u003C")[0].components(separatedBy: "<")[0]
                    if !videoUrls.contains(clean) {
                        videoUrls.append(clean)
                    }
                }
            }

            // Fallback MP4 regex if BaseURL wasn't found
            if videoUrls.isEmpty {
                let mp4Matches = html.extractAllRegex(pattern: #"(https?:[\\/]+[^"'<>]+\.mp4[^"'<>]*)"#)
                for m in mp4Matches {
                    var clean = m.replacingOccurrences(of: "\\/", with: "/")
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "\\u0026", with: "&")
                    clean = clean.components(separatedBy: "\\u003C")[0].components(separatedBy: "<")[0]
                    if !videoUrls.contains(clean) {
                        videoUrls.append(clean)
                    }
                }
            }

            var items: [InstagramMediaItem] = []

            if !videoUrls.isEmpty {
                // Best quality video URL (usually first or largest stream)
                let primaryVideo = videoUrls[0]
                let item = InstagramMediaItem(
                    id: "\(shortcode)_vid_0",
                    type: .video,
                    downloadUrl: primaryVideo,
                    thumbnailUrl: thumbnailUrl,
                    filename: "Instagram_\(defaultKind == .reel ? "Reel" : "Video")_\(shortcode).mp4",
                    width: 1080,
                    height: 1920,
                    displayLabel: defaultKind == .reel ? "Reel Video (1080p MP4)" : "Post Video (MP4)"
                )
                items.append(item)
            } else if let thumb = thumbnailUrl, !thumb.isEmpty {
                // Single Photo Post
                let item = InstagramMediaItem(
                    id: "\(shortcode)_photo_0",
                    type: .photo,
                    downloadUrl: thumb,
                    thumbnailUrl: thumb,
                    filename: "Instagram_Post_\(shortcode).jpg",
                    width: 1080,
                    height: 1080,
                    displayLabel: "Original High-Res Photo"
                )
                items.append(item)
            }

            if !items.isEmpty {
                return InstagramPostInfo(
                    originalUrl: url,
                    kind: defaultKind,
                    author: author,
                    caption: caption,
                    thumbnailUrl: thumbnailUrl,
                    items: items
                )
            }
        } catch {
            AppLogger.shared.log("Meta crawler error: \(error.localizedDescription)", category: .system, level: .warning)
        }

        return nil
    }

    // MARK: - Strategy 2: Cobalt API Extraction (Carousels & Stories)
    private func fetchViaCobalt(url: String, shortcode: String, defaultKind: InstagramPostKind) async -> InstagramPostInfo? {
        var endpointsToTry = cobaltInstances
        if !customApiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            endpointsToTry.insert(customApiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines), at: 0)
        }

        for endpoint in endpointsToTry {
            guard let apiURL = URL(string: endpoint) else { continue }

            var request = URLRequest(url: apiURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 10.0
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cobalt.tools", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X)", forHTTPHeaderField: "User-Agent")

            let bodyDict: [String: Any] = [
                "url": url,
                "vQuality": "max",
                "downloadMode": "auto"
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: bodyDict) else { continue }
            request.httpBody = jsonData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, (httpResp.statusCode == 200 || httpResp.statusCode == 201) else {
                    continue
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let status = json["status"] as? String ?? ""

                // Case 1: Picker (Carousels / Multi-Item Posts)
                if status == "picker", let pickerArray = json["picker"] as? [[String: Any]], !pickerArray.isEmpty {
                    var items: [InstagramMediaItem] = []
                    for (idx, pItem) in pickerArray.enumerated() {
                        let itemTypeStr = pItem["type"] as? String ?? "video"
                        let itemUrl = pItem["url"] as? String ?? ""
                        let itemThumb = pItem["thumb"] as? String

                        guard !itemUrl.isEmpty else { continue }

                        let isVideo = itemTypeStr == "video"
                        let ext = isVideo ? "mp4" : "jpg"
                        let mediaItem = InstagramMediaItem(
                            id: "\(shortcode)_\(idx)",
                            type: isVideo ? .video : .photo,
                            downloadUrl: itemUrl,
                            thumbnailUrl: itemThumb,
                            filename: "Instagram_Slide_\(idx + 1)_\(shortcode).\(ext)",
                            width: 1080,
                            height: isVideo ? 1920 : 1080,
                            displayLabel: "Slide \(idx + 1) (\(isVideo ? "Video" : "Photo"))"
                        )
                        items.append(mediaItem)
                    }

                    if !items.isEmpty {
                        return InstagramPostInfo(
                            originalUrl: url,
                            kind: .carousel,
                            author: "Instagram Creator",
                            caption: "Multi-Item Carousel (\(items.count) items)",
                            thumbnailUrl: items.first?.thumbnailUrl,
                            items: items
                        )
                    }
                }

                // Case 2: Stream / Redirect (Single Video or Photo)
                if (status == "stream" || status == "redirect" || status == "tunnel"), let streamUrl = json["url"] as? String, !streamUrl.isEmpty {
                    let filename = json["filename"] as? String ?? "Instagram_\(shortcode).mp4"
                    let isVideo = filename.lowercased().hasSuffix(".mp4") || streamUrl.contains(".mp4")

                    let singleItem = InstagramMediaItem(
                        id: "\(shortcode)_0",
                        type: isVideo ? .video : .photo,
                        downloadUrl: streamUrl,
                        thumbnailUrl: nil,
                        filename: filename,
                        width: 1080,
                        height: isVideo ? 1920 : 1080,
                        displayLabel: isVideo ? "High-Def Video (MP4)" : "Original Photo"
                    )

                    return InstagramPostInfo(
                        originalUrl: url,
                        kind: defaultKind,
                        author: "Instagram Creator",
                        caption: filename,
                        thumbnailUrl: nil,
                        items: [singleItem]
                    )
                }
            } catch {
                continue
            }
        }

        return nil
    }

    // MARK: - Strategy 3: Embed Fallback
    private func fetchViaEmbed(shortcode: String, defaultKind: InstagramPostKind) async -> InstagramPostInfo? {
        let embedUrlString = "https://www.instagram.com/p/\(shortcode)/embed/captioned/"
        guard let embedUrl = URL(string: embedUrlString) else { return nil }

        var request = URLRequest(url: embedUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 8.0
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else { return nil }
            guard let html = String(data: data, encoding: .utf8) else { return nil }

            var author = "Instagram Creator"
            if let userMatch = html.extractRegex(pattern: #"class="UsernameText">([^<]+)<"#) {
                author = userMatch.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var caption = ""
            if let captionMatch = html.extractRegex(pattern: #"class="Caption"[^>]*>(.*?)</div>"#) {
                caption = captionMatch.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Look for display image
            var imageUrl: String? = nil
            let images = html.extractAllRegex(pattern: #"(https?:\/\/[^\s"'<>]+\.jpg[^\s"'<>]*)"#)
            for im in images {
                let clean = im.replacingOccurrences(of: "\\/", with: "/")
                if clean.contains("cdninstagram.com") && !clean.contains("rsrc.php") {
                    imageUrl = clean
                    break
                }
            }

            if let img = imageUrl {
                let item = InstagramMediaItem(
                    id: "\(shortcode)_embed_0",
                    type: .photo,
                    downloadUrl: img,
                    thumbnailUrl: img,
                    filename: "Instagram_\(shortcode).jpg",
                    width: 1080,
                    height: 1080,
                    displayLabel: "Instagram Photo (Embed)"
                )

                return InstagramPostInfo(
                    originalUrl: "https://www.instagram.com/p/\(shortcode)/",
                    kind: defaultKind,
                    author: author,
                    caption: caption,
                    thumbnailUrl: img,
                    items: [item]
                )
            }
        } catch {
            return nil
        }

        return nil
    }

    // MARK: - Carousel Batch Downloader
    func downloadAllItems(items: [InstagramMediaItem], with downloadEngine: DirectDownloadEngine) async {
        guard !items.isEmpty else { return }

        self.isBatchDownloading = true
        self.batchTotalCount = items.count
        self.batchCurrentIndex = 0

        for (idx, item) in items.enumerated() {
            self.batchCurrentIndex = idx + 1
            self.batchStatusMessage = "Downloading Item \(idx + 1) of \(items.count)..."

            downloadEngine.startDownload(urlString: item.downloadUrl, customFilename: item.filename)

            // Await completion of single download
            while downloadEngine.isDownloading {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        self.isBatchDownloading = false
        self.batchStatusMessage = "All \(items.count) items downloaded & saved to Camera Roll!"
    }
}

// MARK: - String Regex & HTML Decoding Helpers
private extension String {
    func extractRegex(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let nsString = self as NSString
        guard let match = regex.firstMatch(in: self, options: [], range: NSRange(location: 0, length: nsString.length)) else {
            return nil
        }
        if match.numberOfRanges > 1 {
            return nsString.substring(with: match.range(at: 1))
        }
        return nsString.substring(with: match.range)
    }

    func extractAllRegex(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let nsString = self as NSString
        let matches = regex.matches(in: self, options: [], range: NSRange(location: 0, length: nsString.length))
        return matches.compactMap { match in
            if match.numberOfRanges > 1 {
                return nsString.substring(with: match.range(at: 1))
            }
            return nsString.substring(with: match.range)
        }
    }

    func htmlUnescaped() -> String {
        return self
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
