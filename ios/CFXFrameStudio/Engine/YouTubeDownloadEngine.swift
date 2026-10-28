import Foundation

struct YouTubeQualityOption: Identifiable, Hashable {
    let id: String
    let label: String
    let resolution: Int
    let format: String
    let videoCodec: String
    let audioCodec: String
    let downloadUrl: String
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

    // Reliable public fallback extractor APIs
    private let fallbackApis = [
        "https://api.piped.private.coffee/streams/",
        "https://pipedapi.tokhmi.xyz/streams/",
        "https://piped-api.lunar.icu/streams/"
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

        // If user configured a custom yt-dlp backend
        if !customApiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let info = await fetchFromCustomBackend(videoId: videoId, endpoint: customApiEndpoint) {
                self.videoInfo = info
                self.isFetching = false
                return
            }
        }

        // Try public community extractors in sequence
        for base in fallbackApis {
            let apiUrlString = base + videoId
            if let info = await fetchFromPiped(apiUrlString: apiUrlString, videoId: videoId) {
                self.videoInfo = info
                self.isFetching = false
                return
            }
        }

        self.isFetching = false
        self.errorMessage = "Could not extract video streams from YouTube. Please verify the link or enter a custom backend."
    }

    private func fetchFromPiped(apiUrlString: String, videoId: String) async -> YouTubeVideoInfo? {
        guard let url = URL(string: apiUrlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let title = json["title"] as? String ?? "YouTube Video"
            let uploader = json["uploader"] as? String ?? "Unknown Channel"
            let duration = json["duration"] as? Int ?? 0
            let thumbnail = json["thumbnailUrl"] as? String

            var options: [YouTubeQualityOption] = []

            // Check combined streams (Video + Audio) - directly Camera Roll compatible!
            if let streams = json["videoStreams"] as? [[String: Any]] {
                for s in streams {
                    guard let streamUrl = s["url"] as? String else { continue }
                    let quality = s["quality"] as? String ?? "360p"
                    let format = s["format"] as? String ?? "MP4"
                    let codec = s["codec"] as? String ?? "H.264"
                    let videoOnly = s["videoOnly"] as? Bool ?? false
                    let approximateBytes = s["bitrate"] as? Int64

                    let resInt = parseResolutionNumber(quality)
                    let isCompatible = (format.uppercased().contains("MP4") || format.uppercased().contains("M4V")) && !videoOnly

                    let label: String
                    if videoOnly {
                        label = "\(quality) (Video Only • \(codec))"
                    } else {
                        label = "\(quality) (Direct Camera Roll • \(format))"
                    }

                    let opt = YouTubeQualityOption(
                        id: "\(quality)_\(format)_\(videoOnly ? "vo" : "va")",
                        label: label,
                        resolution: resInt,
                        format: format.uppercased(),
                        videoCodec: codec,
                        audioCodec: videoOnly ? "None" : "AAC",
                        downloadUrl: streamUrl,
                        approximateBytes: approximateBytes,
                        isCameraRollCompatible: isCompatible
                    )
                    options.append(opt)
                }
            }

            // Audio-only streams
            if let audioStreams = json["audioStreams"] as? [[String: Any]] {
                for a in audioStreams {
                    guard let streamUrl = a["url"] as? String else { continue }
                    let quality = a["quality"] as? String ?? "Audio"
                    let format = a["format"] as? String ?? "M4A"
                    let codec = a["codec"] as? String ?? "AAC"
                    let approximateBytes = a["bitrate"] as? Int64

                    let opt = YouTubeQualityOption(
                        id: "audio_\(quality)_\(format)",
                        label: "Audio Only (\(quality) • \(format))",
                        resolution: 0,
                        format: format.uppercased(),
                        videoCodec: "None",
                        audioCodec: codec,
                        downloadUrl: streamUrl,
                        approximateBytes: approximateBytes,
                        isCameraRollCompatible: format.uppercased() == "M4A"
                    )
                    options.append(opt)
                }
            }

            guard !options.isEmpty else { return nil }

            // Sort: highest resolution first, then audio
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

    private func fetchFromCustomBackend(videoId: String, endpoint: String) async -> YouTubeVideoInfo? {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.hasSuffix("/") { base += "/" }
        let fullUrlString = base + videoId
        return await fetchFromPiped(apiUrlString: fullUrlString, videoId: videoId)
    }

    private func parseResolutionNumber(_ quality: String) -> Int {
        let cleaned = quality.lowercased().replacingOccurrences(of: "p", with: "").trimmingCharacters(in: .letters)
        return Int(cleaned) ?? 0
    }
}
