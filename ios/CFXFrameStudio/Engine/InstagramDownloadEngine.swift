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

        AppLogger.shared.log(tag: "INSTAGRAM", message: "Analyzing Instagram URL [\(initialKind.rawValue)]: \(cleanedUrl)")

        // 1. Direct Meta-Crawler Ingestion (High-Speed Direct Native Extraction)
        if let metaResult = await fetchViaMetaCrawler(url: cleanedUrl, shortcode: shortcode, defaultKind: initialKind) {
            // If the post has multiple items (Carousel), return it immediately
            if metaResult.items.count > 1 {
                self.postInfo = metaResult
                self.isFetching = false
                AppLogger.shared.log(tag: "INSTAGRAM", message: "Extracted carousel via Meta Crawler with \(metaResult.items.count) slides")
                return
            }

            // If it's a post (/p/) with only 1 item, check Cobalt in case it is a multi-image carousel
            if initialKind == .post {
                if let cobaltResult = await fetchViaCobalt(url: cleanedUrl, shortcode: shortcode, defaultKind: initialKind) {
                    if cobaltResult.items.count > 1 {
                        self.postInfo = cobaltResult
                        self.isFetching = false
                        AppLogger.shared.log(tag: "INSTAGRAM", message: "Extracted multi-image carousel via Cobalt with \(cobaltResult.items.count) slides")
                        return
                    }
                }
            }

            // Single item post or reel
            self.postInfo = metaResult
            self.isFetching = false
            AppLogger.shared.log(tag: "INSTAGRAM", message: "Extracted single media item via Meta Crawler")
            return
        }

        // 2. Cobalt API / Custom Instance (Fallback for Carousels and Stories)
        if let cobaltResult = await fetchViaCobalt(url: cleanedUrl, shortcode: shortcode, defaultKind: initialKind) {
            self.postInfo = cobaltResult
            self.isFetching = false
            AppLogger.shared.log(tag: "INSTAGRAM", message: "Successfully extracted Instagram media via Cobalt (\(cobaltResult.items.count) item(s))")
            return
        }

        // 3. Instagram Public Embed Fallback
        if let embedResult = await fetchViaEmbed(shortcode: shortcode, defaultKind: initialKind) {
            self.postInfo = embedResult
            self.isFetching = false
            AppLogger.shared.log(tag: "INSTAGRAM", message: "Extracted media via Instagram embed fallback")
            return
        }

        self.errorMessage = "Could not extract media from this Instagram link. The post or account might be private or restricted."
        AppLogger.shared.error(tag: "INSTAGRAM", message: "Failed to extract Instagram link: \(cleanedUrl)")
        self.isFetching = false
    }

    // MARK: - Strategy 1: Meta-Crawler Direct Ingestion (With Carousel Discovery)
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

            // Extract Primary Thumbnail from og:image
            var thumbnailUrl: String? = nil
            if let ogImage = html.extractRegex(pattern: #"<meta[^>]+property=['"]og:image['"][^>]+content=['"]([^'"]+)['"]"#) {
                thumbnailUrl = ogImage.htmlUnescaped()
            }

            // Extract High-Def Video Streams from BaseURL or mp4 regex
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

            // Extract ALL Carousel Images (display_url, display_resources, and scontent image URLs)
            var extractedPhotoUrls: [String] = []
            var seenPhotoKeys = Set<String>()

            // 1. High-resolution display_url occurrences
            let displayUrlMatches = html.extractAllRegex(pattern: #""display_url"\s*:\s*"([^"]+)""#)
            for dUrl in displayUrlMatches {
                let clean = dUrl.htmlUnescaped()
                if clean.contains("cdninstagram.com") && !clean.contains("150x150") && !clean.contains("rsrc.php") {
                    let photoKey = Self.extractPhotoIdentifier(from: clean)
                    if !seenPhotoKeys.contains(photoKey) {
                        seenPhotoKeys.insert(photoKey)
                        extractedPhotoUrls.append(clean)
                    }
                }
            }

            // 2. Additional CDN jpg URLs in page data
            let allJpgMatches = html.extractAllRegex(pattern: #"(https?:[\\/]+[^"'<>]+\.jpg[^"'<>]*)"#)
            for jUrl in allJpgMatches {
                let clean = jUrl.htmlUnescaped()
                if clean.contains("scontent") && clean.contains("cdninstagram.com") &&
                   !clean.contains("150x150") && !clean.contains("s150x150") && !clean.contains("rsrc.php") &&
                   !clean.contains("favicon") && !clean.contains("null") {
                    let photoKey = Self.extractPhotoIdentifier(from: clean)
                    if !seenPhotoKeys.contains(photoKey) {
                        seenPhotoKeys.insert(photoKey)
                        extractedPhotoUrls.append(clean)
                    }
                }
            }

            // 3. Fallback to og:image if no other photos found
            if extractedPhotoUrls.isEmpty, let thumb = thumbnailUrl, !thumb.isEmpty {
                extractedPhotoUrls.append(thumb)
            }

            var items: [InstagramMediaItem] = []

            // If it has multiple photos, or both videos and photos -> Carousel!
            let isCarousel = (extractedPhotoUrls.count > 1) || (!videoUrls.isEmpty && extractedPhotoUrls.count > 1)
            let finalKind: InstagramPostKind = isCarousel ? .carousel : defaultKind

            // Add Videos
            for (vIdx, vUrl) in videoUrls.prefix(isCarousel ? 10 : 1).enumerated() {
                let item = InstagramMediaItem(
                    id: "\(shortcode)_vid_\(vIdx)",
                    type: .video,
                    downloadUrl: vUrl,
                    thumbnailUrl: thumbnailUrl,
                    filename: isCarousel ? "Instagram_Slide_\(vIdx + 1)_\(shortcode).mp4" : "Instagram_\(defaultKind == .reel ? "Reel" : "Video")_\(shortcode).mp4",
                    width: 1080,
                    height: 1920,
                    displayLabel: isCarousel ? "Slide \(vIdx + 1) (Video MP4)" : (defaultKind == .reel ? "Reel Video (1080p MP4)" : "Post Video (MP4)")
                )
                items.append(item)
            }

            // Add Photos (If video already added and not a carousel, don't duplicate video thumb as a photo)
            if items.isEmpty || isCarousel {
                let offset = items.count
                for (pIdx, pUrl) in extractedPhotoUrls.enumerated() {
                    let slideNum = offset + pIdx + 1
                    let item = InstagramMediaItem(
                        id: "\(shortcode)_photo_\(pIdx)",
                        type: .photo,
                        downloadUrl: pUrl,
                        thumbnailUrl: pUrl,
                        filename: isCarousel ? "Instagram_Slide_\(slideNum)_\(shortcode).jpg" : "Instagram_Post_\(shortcode).jpg",
                        width: 1080,
                        height: 1080,
                        displayLabel: isCarousel ? "Slide \(slideNum) (Photo)" : "Original High-Res Photo"
                    )
                    items.append(item)
                }
            }

            if !items.isEmpty {
                return InstagramPostInfo(
                    originalUrl: url,
                    kind: finalKind,
                    author: author,
                    caption: caption,
                    thumbnailUrl: thumbnailUrl ?? items.first?.thumbnailUrl,
                    items: items
                )
            }
        } catch {
            AppLogger.shared.error(tag: "INSTAGRAM", message: "Meta crawler error: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - Photo Identifier for Deduplication
    private static func extractPhotoIdentifier(from url: String) -> String {
        guard let urlObj = URL(string: url) else { return url }
        let filename = urlObj.lastPathComponent
        // Strip trailing query parameters
        let base = filename.components(separatedBy: "?").first ?? filename
        // Remove resolution tags like _s1080x1080 to match different sizes of the same image
        if let regex = try? NSRegularExpression(pattern: #"_s\d+x\d+"#) {
            let ns = base as NSString
            let range = NSRange(location: 0, length: ns.length)
            return regex.stringByReplacingMatches(in: base, range: range, withTemplate: "")
        }
        return base
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
            self.batchStatusMessage = "Downloading Slide \(idx + 1) of \(items.count)..."

            guard let url = URL(string: item.downloadUrl) else { continue }

            do {
                let (tempUrl, _) = try await URLSession.shared.download(from: url)
                let ext = item.type == .video ? "mp4" : "jpg"
                let targetFilename = "CFX_Insta_Slide_\(idx + 1)_\(UUID().uuidString.prefix(6)).\(ext)"
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let localUrl = docs.appendingPathComponent(targetFilename)

                try? FileManager.default.removeItem(at: localUrl)
                try FileManager.default.moveItem(at: tempUrl, to: localUrl)

                // Save directly to iOS Photos Camera Roll
                if item.type == .video {
                    _ = await downloadEngine.saveVideoToPhotos(url: localUrl)
                } else {
                    _ = await downloadEngine.saveImageToPhotos(url: localUrl)
                }

                AppLogger.shared.log(tag: "INSTAGRAM", message: "Saved Slide \(idx + 1) to Camera Roll: \(targetFilename)")
            } catch {
                AppLogger.shared.error(tag: "INSTAGRAM", message: "Failed downloading Slide \(idx + 1): \(error.localizedDescription)")
            }
        }

        self.isBatchDownloading = false
        self.batchStatusMessage = "All \(items.count) carousel items saved to Photos!"
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
