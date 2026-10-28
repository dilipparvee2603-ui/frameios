import Foundation

struct YouTubeQualityOption: Identifiable, Hashable {
    let id: String
    let label: String
    let resolution: Int
    let format: String
    let videoCodec: String
    let audioCodec: String
    let downloadUrl: String
    let audioUrl: String?
    let approximateBytes: Int64?
    let isCameraRollCompatible: Bool

    var displaySize: String {
        guard let bytes = approximateBytes, bytes > 0 else { return "" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}

struct YouTubeVideoInfo {
    let videoId: String
    let title: String
    let author: String
    let thumbnailUrl: String?
    let durationSec: Int
    let qualities: [YouTubeQualityOption]
}

@MainActor
final class YouTubeDownloadEngine: ObservableObject {
    @Published var isFetching: Bool = false
    @Published var videoInfo: YouTubeVideoInfo? = nil
    @Published var errorMessage: String? = nil
    @Published var customApiEndpoint: String = ""

    // Reliable Invidious and Piped fallback instances
    private let fallbackApis = [
        "https://yt.chocolatemoo53.com/api/v1/videos/",
        "https://invidious.projectsegfau.lt/api/v1/videos/",
        "https://invidious.slipfox.xyz/api/v1/videos/",
        "https://invidious.nerdvpn.de/api/v1/videos/",
        "https://api.piped.private.coffee/streams/"
    ]

    static func isYouTubeUrl(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("youtube.com/watch") ||
               lower.contains("youtu.be/") ||
               lower.contains("youtube.com/shorts/") ||
               lower.contains("youtube.com/embed/")
    }

    static func extractVideoId(from urlString: String) -> String? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }

        if url.host?.contains("youtu.be") == true {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.components(separatedBy: "/").first
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let videoId = components.queryItems?.first(where: { $0.name == "v" })?.value {
                return videoId
            }
            if url.path.contains("/shorts/") {
                return url.path.components(separatedBy: "/shorts/").last?.components(separatedBy: "/").first
            }
            if url.path.contains("/embed/") {
                return url.path.components(separatedBy: "/embed/").last?.components(separatedBy: "/").first
            }
        }
        return nil
    }

    func fetchQualities(for urlString: String) async {
        guard let videoId = Self.extractVideoId(from: urlString) else {
            self.errorMessage = "Could not extract YouTube video ID from the link."
            return
        }

        self.isFetching = true
        self.errorMessage = nil
        self.videoInfo = nil

        // If user configured a custom backend
        if !customApiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let info = await fetchFromEndpoint(base: customApiEndpoint, videoId: videoId) {
                self.videoInfo = info
                self.isFetching = false
                return
            }
        }

        // Try instances in sequence
        for base in fallbackApis {
            if let info = await fetchFromEndpoint(base: base, videoId: videoId) {
                self.videoInfo = info
                self.isFetching = false
                return
            }
        }

        self.isFetching = false
        self.errorMessage = "Could not extract video streams. Please check the link or try another video."
    }

    private func fetchFromEndpoint(base: String, videoId: String) async -> YouTubeVideoInfo? {
        var cleanBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanBase.hasSuffix("/") { cleanBase += "/" }
        let fullUrlString = cleanBase + videoId

        guard let url = URL(string: fullUrlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let title = (json["title"] as? String) ?? "YouTube Video"
            guard !title.isEmpty else { return nil }

            let uploader = (json["author"] as? String) ?? (json["uploader"] as? String) ?? "YouTube Channel"
            let duration = (json["lengthSeconds"] as? Int) ?? (json["duration"] as? Int) ?? 0

            var thumbnail: String? = nil
            if let thumbs = json["videoThumbnails"] as? [[String: Any]], let first = thumbs.first {
                thumbnail = first["url"] as? String
            } else {
                thumbnail = json["thumbnailUrl"] as? String
            }

            var options: [YouTubeQualityOption] = []
            var seenResolutions = Set<String>()

            // Find best audio stream (prefer AAC / M4A for Camera Roll compatibility)
            var bestAudioUrl: String? = nil
            var bestAudioBytes: Int64? = nil

            if let adaptive = json["adaptiveFormats"] as? [[String: Any]] {
                let audioFormats = adaptive.filter { ($0["type"] as? String)?.contains("audio") == true }
                // Prefer m4a / aac
                let m4aAudio = audioFormats.first { ($0["container"] as? String)?.lowercased() == "m4a" } ?? audioFormats.first
                if let a = m4aAudio, let aUrl = a["url"] as? String {
                    bestAudioUrl = aUrl
                    var aBytes = (a["clen"] as? String).flatMap { Int64($0) }
                    if aBytes == nil, let bit = a["bitrate"] as? Int64, duration > 0 {
                        aBytes = (bit * Int64(duration)) / 8
                    }
                    bestAudioBytes = aBytes
                }
            } else if let audioStreams = json["audioStreams"] as? [[String: Any]], let first = audioStreams.first {
                bestAudioUrl = first["url"] as? String
                if let bit = first["bitrate"] as? Int64, duration > 0 {
                    bestAudioBytes = (bit * Int64(duration)) / 8
                }
            }

            // 1. Process Combined formatStreams (e.g. 720p, 360p)
            if let formatStreams = json["formatStreams"] as? [[String: Any]] {
                for s in formatStreams {
                    guard let streamUrl = s["url"] as? String else { continue }
                    let quality = s["qualityLabel"] as? String ?? s["resolution"] as? String ?? "720p"
                    let container = (s["container"] as? String ?? "mp4").uppercased()
                    let encoding = (s["encoding"] as? String ?? "h264").uppercased()

                    let resInt = parseResolutionNumber(quality)
                    let key = "\(resInt)_\(container)_combined"
                    guard !seenResolutions.contains(key) else { continue }
                    seenResolutions.insert(key)

                    let opt = YouTubeQualityOption(
                        id: key,
                        label: "\(quality) (Complete • \(container))",
                        resolution: resInt,
                        format: container,
                        videoCodec: encoding,
                        audioCodec: "AAC",
                        downloadUrl: streamUrl,
                        audioUrl: nil,
                        approximateBytes: (s["clen"] as? String).flatMap { Int64($0) } ?? (s["bitrate"] as? Int64),
                        isCameraRollCompatible: container == "MP4"
                    )
                    options.append(opt)
                }
            }

            // 2. Process High-Resolution Adaptive Formats (1080p, 1440p 2K, 4K, 8K)
            if let adaptive = json["adaptiveFormats"] as? [[String: Any]] {
                let videoAdaptive = adaptive.filter {
                    guard let res = $0["resolution"] as? String, !res.isEmpty else { return false }
                    return true
                }

                for v in videoAdaptive {
                    guard let streamUrl = v["url"] as? String else { continue }
                    let quality = v["qualityLabel"] as? String ?? v["resolution"] as? String ?? "1080p"
                    let container = (v["container"] as? String ?? "mp4").uppercased()

                    let rawEncoding = (v["encoding"] as? String ?? "").uppercased()
                    let rawType = (v["type"] as? String ?? "").uppercased()
                    let isH264 = rawEncoding.contains("H264") || rawEncoding.contains("AVC") || rawType.contains("AVC1") || rawType.contains("H264")
                    let encoding = isH264 ? "H.264" : (rawEncoding.isEmpty ? (rawType.contains("VP9") ? "VP9" : (rawType.contains("AV01") ? "AV01" : "MP4V")) : rawEncoding)

                    let resInt = parseResolutionNumber(quality)

                    // Key to avoid duplicate entries for the same resolution & container
                    let key = "\(resInt)_\(container)_\(encoding)"
                    guard !seenResolutions.contains(key) else { continue }
                    seenResolutions.insert(key)

                    let isCompatible = container == "MP4" && isH264
                    let canMuxAudio = (container == "MP4") && (bestAudioUrl != nil)

                    let label: String
                    if resInt >= 2160 {
                        label = "4K (\(quality) • \(container))"
                    } else if resInt >= 1440 {
                        label = "2K (\(quality) • \(container))"
                    } else if resInt >= 1080 {
                        label = canMuxAudio ? "1080p Full HD (MP4 + Audio)" : "1080p (\(quality) • \(container))"
                    } else if resInt >= 720 {
                        label = canMuxAudio ? "720p HD (MP4 + Audio)" : "720p (\(quality) • \(container))"
                    } else {
                        label = "\(quality) (\(container))"
                    }

                    var videoBytes = (v["clen"] as? String).flatMap { Int64($0) }
                    if videoBytes == nil, let bit = v["bitrate"] as? Int64, duration > 0 {
                        videoBytes = (bit * Int64(duration)) / 8
                    }
                    let totalApproxBytes: Int64? = canMuxAudio ? ((videoBytes ?? 0) + (bestAudioBytes ?? 0)) : videoBytes

                    let opt = YouTubeQualityOption(
                        id: key,
                        label: label,
                        resolution: resInt,
                        format: container,
                        videoCodec: encoding,
                        audioCodec: canMuxAudio ? "AAC" : "None",
                        downloadUrl: streamUrl,
                        audioUrl: canMuxAudio ? bestAudioUrl : nil,
                        approximateBytes: totalApproxBytes,
                        isCameraRollCompatible: isCompatible
                    )
                    options.append(opt)
                }
            }

            // 3. Audio-Only Option
            if let aUrl = bestAudioUrl {
                let opt = YouTubeQualityOption(
                    id: "audio_best_m4a",
                    label: "Audio Only (M4A • 128 kbps)",
                    resolution: 0,
                    format: "M4A",
                    videoCodec: "None",
                    audioCodec: "AAC",
                    downloadUrl: aUrl,
                    audioUrl: nil,
                    approximateBytes: bestAudioBytes,
                    isCameraRollCompatible: true
                )
                options.append(opt)
            }

            guard !options.isEmpty else { return nil }

            // Sort: Highest resolution first
            options.sort { o1, o2 in
                if o1.resolution != o2.resolution {
                    return o1.resolution > o2.resolution
                }
                return o1.isCameraRollCompatible && !o2.isCameraRollCompatible
            }

            return YouTubeVideoInfo(
                videoId: videoId,
                title: title,
                author: uploader,
                thumbnailUrl: thumbnail,
                durationSec: duration,
                qualities: options
            )
        } catch {
            return nil
        }
    }

    private func parseResolutionNumber(_ quality: String) -> Int {
        let digits = quality.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits) ?? 0
    }
}
