import Foundation
import AVFoundation
import UIKit
import Combine
import ffmpegkit

/// Aspect ratio display modes for the VLC-style player
enum PlayerAspectRatioMode: String, CaseIterable, Identifiable {
    case fit = "Fit (Default)"
    case fill = "Fill Screen"
    case ratio16_9 = "16:9 Widescreen"
    case ratio4_3 = "4:3 Standard"
    case ratio21_9 = "21:9 Cinema"
    case original = "Original (1:1)"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .fit: return "arrow.up.left.and.arrow.down.right"
        case .fill: return "arrow.up.left.and.down.right.magnifyingglass"
        case .ratio16_9: return "rectangle.ratio.16.to.9"
        case .ratio4_3: return "rectangle.ratio.4.to.3"
        case .ratio21_9: return "film"
        case .original: return "aspectratio"
        }
    }
}

/// Sleep timer options
enum PlayerSleepTimer: Int, CaseIterable, Identifiable {
    case off = 0
    case min15 = 15
    case min30 = 30
    case min45 = 45
    case min60 = 60
    case endOfVideo = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .min15: return "15 Minutes"
        case .min30: return "30 Minutes"
        case .min45: return "45 Minutes"
        case .min60: return "60 Minutes"
        case .endOfVideo: return "End of Video"
        }
    }
}

/// Detailed media metadata inspected directly from file
struct UniversalMediaMetadata {
    var title: String = ""
    var container: String = ""
    var videoCodec: String = ""
    var audioCodec: String = ""
    var width: Int = 0
    var height: Int = 0
    var resolution: CGSize = .zero
    var frameRate: Double = 0.0
    var bitrateKbps: Int64 = 0
    var durationSec: Double = 0.0
    var audioChannels: Int = 2
    var audioSampleRate: Int = 48000
    var fileSizeFormatted: String = ""
}

@MainActor
final class UniversalPlayerEngine: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var isBuffering: Bool = false
    @Published var statusMessage: String? = nil

    // Controls & Settings
    @Published var playbackRate: Float = 1.0
    @Published var aspectRatioMode: PlayerAspectRatioMode = .fit
    @Published var volume: Float = 1.0 // 0.0 to 2.0 (200% VLC Boost)
    @Published var brightness: Float = 0.5
    @Published var isControlsLocked: Bool = false
    @Published var sleepTimer: PlayerSleepTimer = .off
    @Published var sleepTimerRemainingSeconds: Int = 0

    // A-B Looping
    @Published var loopPointA: Double? = nil
    @Published var loopPointB: Double? = nil
    @Published var isLoopingAB: Bool = false

    // Zoom & Pan
    @Published var zoomScale: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero

    // Resume / Continue Playing State
    @Published var lastSavedPosition: Double? = nil
    @Published var hasResumedPlayback: Bool = false
    private var lastAutoSaveTime: Date = Date()

    // Streaming State
    private var streamProcessTask: Task<Void, Never>?
    private var activeStreamDirectory: URL?
    private var isStreamingHLS: Bool = false
    private var streamSeekBaseOffset: Double = 0.0

    // Metadata
    @Published var metadata: UniversalMediaMetadata = UniversalMediaMetadata()
    @Published var currentSourceUrl: URL? = nil

    // MARK: - Internal Player
    var player: AVPlayer?
    private var timeObserverToken: Any?
    private var sleepTimerTask: Task<Void, Never>?
    private var playerItemStatusObserver: NSKeyValueObservation?

    override init() {
        super.init()
        self.brightness = Float(UIScreen.main.brightness)
    }

    deinit {
        sleepTimerTask?.cancel()
    }

    func cleanUp() {
        savePlaybackPosition()
        streamProcessTask?.cancel()
        streamProcessTask = nil
        FFmpegKit.cancel()
        if let dir = activeStreamDirectory {
            try? FileManager.default.removeItem(at: dir)
            activeStreamDirectory = nil
        }
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        player = nil
    }

    // MARK: - Media Loading

    /// Loads and plays any video file (MKV, AVI, WebM, MP4, MOV, FLV, WMV, etc.)
    func loadMedia(url: URL) async {
        cleanUp()
        self.currentSourceUrl = url
        self.currentTime = 0.0
        self.duration = 0.0
        self.loopPointA = nil
        self.loopPointB = nil
        self.isLoopingAB = false
        self.zoomScale = 1.0
        self.panOffset = .zero
        self.hasResumedPlayback = false
        self.lastSavedPosition = nil

        // Immediate 2ms container & codec binary scan
        let isNonNative = MKVRemuxEngine.isNonNativeContainer(url: url)
        let binScan = MKVRemuxEngine.fastBinaryScan(url: url)
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        self.metadata = UniversalMediaMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            container: url.pathExtension.uppercased(),
            fileSizeFormatted: ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        )

        // Check if there is a saved resume position
        let savedResumePos = getSavedPlaybackPosition(for: url)

        // Asynchronously probe full media metadata in the background so it never stalls instant playback
        Task { [weak self] in
            await self?.probeMediaInfo(url: url)
        }

        var playableUrl = url
        let ext = url.pathExtension.lowercased()
        let isNativeContainer = (ext == "mp4" || ext == "mov" || ext == "m4v")
        let needsRemuxOrStream = isNonNative || (!isNativeContainer && (binScan.hasHev1 || binScan.hasAc3 || binScan.hasEc3 || binScan.hasDts)) || binScan.hasDts

        if needsRemuxOrStream {
            self.statusMessage = "Opening stream..."
            self.isBuffering = true

            // First check if an existing fast remux was already cached
            if let cached = MKVRemuxEngine.getExistingCachedRemux(for: url) {
                playableUrl = cached
            } else {
                // INSTANT STREAMING: Direct stream-copy chunks in real time (< 0.2s startup)
                do {
                    playableUrl = try await startStreaming(sourceUrl: url, seekOffset: savedResumePos ?? 0.0)
                } catch {
                    AppLogger.shared.error(tag: "PLAYER", message: "Instant stream failed, falling back to progressive remux: \(error.localizedDescription)")
                    self.statusMessage = "Buffering..."
                    if let fallback = try? await MKVRemuxEngine.shared.remuxToMP4(sourceUrl: url, onProgress: { [weak self] progress, _ in
                        Task { @MainActor in
                            self?.statusMessage = "Buffering: \(Int(progress * 100))%"
                        }
                    }) {
                        playableUrl = fallback
                    }
                }
            }
        } else {
            // 100% Native Apple format (Photos, Camera Roll, standard MP4/MOV) - zero buffering, direct playback!
            self.statusMessage = nil
            self.isBuffering = false
        }

        // Initialize AVPlayer
        setupPlayer(url: playableUrl, initialResumePos: savedResumePos)
    }

    private func startStreaming(sourceUrl: URL, seekOffset: Double = 0.0) async throws -> URL {
        streamProcessTask?.cancel()
        streamProcessTask = nil
        FFmpegKit.cancel()
        if let dir = activeStreamDirectory {
            try? FileManager.default.removeItem(at: dir)
            activeStreamDirectory = nil
        }

        let streamDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfx_stream_\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: streamDir, withIntermediateDirectories: true)
        self.activeStreamDirectory = streamDir
        self.isStreamingHLS = true
        self.streamSeekBaseOffset = seekOffset

        let playlistUrl = streamDir.appendingPathComponent("live.m3u8")
        let initUrl = streamDir.appendingPathComponent("init.mp4")
        let segmentPattern = streamDir.appendingPathComponent("segment_%03d.m4s")
        let firstSegmentUrl = streamDir.appendingPathComponent("segment_000.m4s")

        let binScan = MKVRemuxEngine.fastBinaryScan(url: sourceUrl)
        let nameLower = sourceUrl.lastPathComponent.lowercased()
        let isHEVC = binScan.hasHev1 || nameLower.contains("hevc") || nameLower.contains("x265") || nameLower.contains("h265")

        var args = ["-threads", "0", "-y"]
        if seekOffset > 1.0 {
            args += ["-ss", String(format: "%.3f", seekOffset)]
        }
        args += [
            "-i", sourceUrl.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "copy"
        ]
        if isHEVC {
            args += ["-tag:v", "hvc1"]
        } else {
            args += ["-tag:v", "avc1"]
        }
        args += [
            "-c:a", "aac",
            "-b:a", "256k",
            "-ac", "2",
            "-f", "hls",
            "-hls_time", "2",
            "-hls_list_size", "0",
            "-hls_segment_type", "fmp4",
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", segmentPattern.path,
            "-hls_flags", "independent_segments",
            playlistUrl.path
        ]

        streamProcessTask = Task.detached(priority: .userInitiated) {
            let session = FFmpegKit.execute(withArguments: args)
            let returnCode = session?.getReturnCode()
            if !ReturnCode.isSuccess(returnCode) && !ReturnCode.isCancel(returnCode) {
                let logs = session?.getAllLogsAsString() ?? session?.getFailStackTrace() ?? "Unknown error"
                AppLogger.shared.error(tag: "STREAM", message: "HLS FFmpeg execution error: \(logs)")
            }
        }

        // Wait until playlist, init.mp4, and the first segment are all written to disk
        var elapsedMs = 0
        while (!FileManager.default.fileExists(atPath: playlistUrl.path) ||
               !FileManager.default.fileExists(atPath: initUrl.path) ||
               !FileManager.default.fileExists(atPath: firstSegmentUrl.path)) && elapsedMs < 8000 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            elapsedMs += 50
        }

        guard FileManager.default.fileExists(atPath: playlistUrl.path) &&
              FileManager.default.fileExists(atPath: initUrl.path) &&
              FileManager.default.fileExists(atPath: firstSegmentUrl.path) else {
            throw NSError(domain: "UniversalPlayerEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream initialization timed out."])
        }

        return playlistUrl
    }

    private func setupPlayer(url: URL, initialResumePos: Double? = nil) {
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.actionAtItemEnd = .none
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        self.player = avPlayer
        self.playbackRate = 1.0
        avPlayer.rate = 1.0
        self.isPlaying = true
        self.isBuffering = isStreamingHLS

        // Observe Item Status
        playerItemStatusObserver = playerItem.observe(\.status, options: [.new, .old]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.statusMessage = nil
                    if self.isPlaying {
                        self.player?.play()
                    }
                case .failed:
                    self.isBuffering = false
                    let errMsg = item.error?.localizedDescription ?? "Playback failed"
                    self.statusMessage = errMsg
                    AppLogger.shared.error(tag: "PLAYER", message: "AVPlayerItem failed: \(errMsg)")
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        // Set volume with 200% boost capability
        applyVolume(self.volume)

        // Resume position if saved
        if let resumePos = initialResumePos, resumePos > 5.0 && resumePos < (self.duration - 10.0) {
            self.lastSavedPosition = resumePos
            self.hasResumedPlayback = true
            if !isStreamingHLS {
                seek(to: resumePos)
            } else {
                self.currentTime = resumePos
            }
        }

        // Observe Item Status & End
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnded()
            }
        }

        // Time Observer (60fps accuracy)
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let rawSecs = time.seconds
            guard !rawSecs.isNaN && !rawSecs.isInfinite else { return }

            let effectiveSecs = self.isStreamingHLS ? (self.streamSeekBaseOffset + rawSecs) : rawSecs
            self.currentTime = min(self.duration > 0 ? self.duration : effectiveSecs, effectiveSecs)

            // Auto-save playback position every 4 seconds
            if Date().timeIntervalSince(self.lastAutoSaveTime) >= 4.0 {
                self.lastAutoSaveTime = Date()
                self.savePlaybackPosition()
            }

            // Read duration if not yet set
            if self.duration <= 0, let itemDuration = self.player?.currentItem?.duration.seconds, !itemDuration.isNaN && !itemDuration.isInfinite && itemDuration > 0 {
                self.duration = itemDuration
            }

            // A-B Looping check
            if self.isLoopingAB, let b = self.loopPointB, self.currentTime >= b {
                let restartA = self.loopPointA ?? 0.0
                self.seek(to: restartA)
            }
        }

        avPlayer.play()
    }

    private func handlePlaybackEnded() {
        if isLoopingAB, let a = loopPointA {
            seek(to: a)
            play()
        } else if sleepTimer == .endOfVideo {
            pause()
            sleepTimer = .off
        } else {
            // Loop or restart to start
            seek(to: 0.0)
            isPlaying = false
        }
    }

    // MARK: - Media Probing

    private func probeMediaInfo(url: URL) async {
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let formattedSize = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)

        var meta = UniversalMediaMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            container: url.pathExtension.uppercased(),
            fileSizeFormatted: formattedSize
        )

        let probeResult = await Task.detached(priority: .userInitiated) { () -> MediaInformation? in
            let session = FFprobeKit.getMediaInformation(url.path)
            return session?.getMediaInformation()
        }.value

        if let info = probeResult {
            meta.durationSec = Double(info.getDuration() ?? "0") ?? 0
            if meta.durationSec > 0 {
                self.duration = meta.durationSec
            }
            meta.bitrateKbps = (Int64(info.getBitrate() ?? "0") ?? 0) / 1000

            if let streams = info.getStreams() as? [StreamInformation] {
                for s in streams {
                    let type = s.getType()?.lowercased() ?? ""
                    let codec = (s.getCodec() ?? "").uppercased()
                    if type == "video" && meta.videoCodec.isEmpty {
                        meta.videoCodec = codec.isEmpty ? "H264" : codec
                        let w = (s.getWidth() as? NSNumber)?.intValue ?? 1920
                        let h = (s.getHeight() as? NSNumber)?.intValue ?? 1080
                        meta.width = Int(w)
                        meta.height = Int(h)
                        meta.resolution = CGSize(width: meta.width, height: meta.height)
                        let rFrame = s.getRealFrameRate() ?? "30/1"
                        let parts = rFrame.split(separator: "/")
                        if parts.count == 2, let num = Double(String(parts[0])), let den = Double(String(parts[1])), den > 0 {
                            meta.frameRate = num / den
                        } else {
                            meta.frameRate = Double(rFrame) ?? 30.0
                        }
                    } else if type == "audio" && meta.audioCodec.isEmpty {
                        meta.audioCodec = codec.isEmpty ? "AAC" : codec
                        let ch = (s.getProperty("channels") as? NSNumber)?.intValue ?? 2
                        let srStr = (s.getProperty("sample_rate") as? String) ?? "48000"
                        meta.audioChannels = Int(ch)
                        meta.audioSampleRate = Int(srStr) ?? 48000
                    }
                }
            }
        }

        self.metadata = meta
    }

    // MARK: - Playback Controls

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        player?.play()
        player?.rate = playbackRate
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        savePlaybackPosition()
    }

    func seek(to seconds: Double) {
        let clamped = max(0.0, min(seconds, duration))
        currentTime = clamped
        if isStreamingHLS {
            guard let url = currentSourceUrl else { return }
            self.isBuffering = true
            Task {
                do {
                    let streamUrl = try await startStreaming(sourceUrl: url, seekOffset: clamped)
                    setupPlayer(url: streamUrl, initialResumePos: nil)
                } catch {
                    AppLogger.shared.error(tag: "PLAYER", message: "Seek streaming error: \(error.localizedDescription)")
                    self.isBuffering = false
                }
            }
        } else {
            let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
            player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        savePlaybackPosition()
    }

    // MARK: - Playback Resume / Continue Watching

    func savePlaybackPosition() {
        guard let url = currentSourceUrl, duration > 10.0 else { return }
        let key = playbackStorageKey(for: url)
        if currentTime < 5.0 || currentTime >= (duration - 10.0) {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(currentTime, forKey: key)
        }
    }

    func getSavedPlaybackPosition(for url: URL) -> Double? {
        let key = playbackStorageKey(for: url)
        let pos = UserDefaults.standard.double(forKey: key)
        if pos > 5.0 {
            return pos
        }
        return nil
    }

    func clearSavedPlaybackPosition(for url: URL) {
        let key = playbackStorageKey(for: url)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func playbackStorageKey(for url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return "CFX_Resume_\(url.lastPathComponent)_\(size)"
    }

    func seekRelative(seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func stepFrame(forward: Bool) {
        pause()
        player?.currentItem?.step(byCount: forward ? 1 : -1)
        if let time = player?.currentTime().seconds, !time.isNaN {
            currentTime = time
        }
    }

    func setPlaybackRate(_ rate: Float) {
        self.playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    // MARK: - Volume & VLC 200% Audio Boost

    func setVolume(_ newVol: Float) {
        let clamped = max(0.0, min(newVol, 2.0))
        self.volume = clamped
        applyVolume(clamped)
    }

    private func applyVolume(_ vol: Float) {
        guard let item = player?.currentItem else { return }
        // 0.0 - 1.0 is standard AVPlayer volume.
        // 1.01 - 2.0 uses audio mix parameters for VLC-style 200% amplification
        if vol <= 1.0 {
            player?.volume = vol
            item.audioMix = nil
        } else {
            player?.volume = 1.0
            let boostGain = vol // 1.01x up to 2.0x volume gain
            let audioTracks = item.asset.tracks(withMediaType: .audio)
            let inputParams = audioTracks.map { track -> AVMutableAudioMixInputParameters in
                let param = AVMutableAudioMixInputParameters(track: track)
                param.setVolume(boostGain, at: .zero)
                return param
            }
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = inputParams
            item.audioMix = audioMix
        }
    }

    // MARK: - Screen Brightness Control

    func setBrightness(_ newBrightness: Float) {
        let clamped = max(0.0, min(newBrightness, 1.0))
        self.brightness = clamped
        UIScreen.main.brightness = CGFloat(clamped)
    }

    // MARK: - A-B Loop Controls

    func setPointA() {
        loopPointA = currentTime
        if let b = loopPointB, b <= currentTime {
            loopPointB = nil
            isLoopingAB = false
        }
    }

    func setPointB() {
        guard let a = loopPointA, currentTime > a else { return }
        loopPointB = currentTime
        isLoopingAB = true
        seek(to: a)
        play()
    }

    func clearABLoop() {
        loopPointA = nil
        loopPointB = nil
        isLoopingAB = false
    }

    // MARK: - Sleep Timer

    func setSleepTimer(_ timer: PlayerSleepTimer) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        self.sleepTimer = timer

        if timer == .off || timer == .endOfVideo {
            self.sleepTimerRemainingSeconds = 0
            return
        }

        self.sleepTimerRemainingSeconds = timer.rawValue * 60
        sleepTimerTask = Task { [weak self] in
            while let self = self, self.sleepTimerRemainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                self.sleepTimerRemainingSeconds -= 1
            }
            guard let self = self, !Task.isCancelled else { return }
            self.pause()
            self.sleepTimer = .off
            self.sleepTimerRemainingSeconds = 0
        }
    }
}
