import Foundation
import AVFoundation
import UIKit

final class PlayerModel: ObservableObject {
    @Published var player: AVPlayer = AVPlayer()
    @Published var isPlaying: Bool = false
    @Published var isMuted: Bool = false
    @Published var currentPositionMs: Int64 = 0
    @Published var currentPositionTime: CMTime = .zero
    @Published var playbackFailed: Bool = false
    @Published var playbackErrorMessage: String? = nil
    @Published var didReachEndTime: Bool = false
    @Published var trimInMs: Int64 = 0
    @Published var trimOutMs: Int64 = .max

    var loopOnEnd: Bool = false
    var periodicTickHandler: ((Int64) -> Void)? = nil
    var onDisplayFrame: ((_ currentSourceSec: Double) -> Void)? = nil

    private var timeObserverToken: Any? = nil
    private var endObserverToken: Any? = nil
    private var statusObserverToken: NSKeyValueObservation? = nil
    private var displayLink: CADisplayLink?
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .rigid)

    init() {
        configureAudioSession()
        ensureTimeObserver()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    /// Sets strict playback range boundaries on the current AVPlayerItem
    func setPlaybackBounds(inMs: Int64, outMs: Int64) {
        self.trimInMs = max(0, inMs)
        self.trimOutMs = max(self.trimInMs + 50, outMs)
        applyPlaybackBounds()
    }

    private func applyPlaybackBounds() {
        guard let item = player.currentItem else { return }
        let outSec = Double(trimOutMs) / 1000.0
        let outCm = CMTime(seconds: outSec, preferredTimescale: 60000)
        item.forwardPlaybackEndTime = outCm
    }

    /// Ensures the periodic time observer is attached to the AVPlayer instance for timeline UI sync
    func ensureTimeObserver() {
        guard timeObserverToken == nil else { return }
        let interval = CMTime(value: 1, timescale: 30) // 30Hz for timeline UI needle to keep main thread light
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentPositionTime = time
            let ms = Int64(CMTimeGetSeconds(time) * 1000.0)
            self.currentPositionMs = ms

            let isActivelyPlaying = self.isPlaying || self.player.rate > 0.001 || self.player.timeControlStatus == .playing
            if isActivelyPlaying {
                if ms >= self.trimOutMs - 25 {
                    self.periodicTickHandler?(self.trimOutMs)
                } else if ms < self.trimInMs - 50 {
                    self.seek(to: self.trimInMs, preservePlaybackState: true)
                } else {
                    self.periodicTickHandler?(ms)
                }
            }
        }
    }

    func setup(with url: URL, onTick: ((Int64) -> Void)? = nil) {
        configureAudioSession()
        didReachEndTime = false
        if let tick = onTick {
            periodicTickHandler = tick
        }

        let playerItem = AVPlayerItem(url: url)
        // High quality pitch algorithm prevents distortion during slow or retimed playback
        playerItem.audioTimePitchAlgorithm = .timeDomain
        let outSec = Double(trimOutMs) / 1000.0
        playerItem.forwardPlaybackEndTime = CMTime(seconds: outSec, preferredTimescale: 60000)

        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        // Loop / reset or notify continuous project playback
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.didReachEndTime = true
            if self.loopOnEnd {
                self.seek(to: self.trimInMs) {
                    self.play()
                }
            } else if self.isPlaying {
                self.periodicTickHandler?(self.trimOutMs)
            }
        }

        if let token = statusObserverToken {
            token.invalidate()
            statusObserverToken = nil
        }
        statusObserverToken = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .failed {
                    let errMsg = item.error?.localizedDescription ?? "Playback failed"
                    print("AVPlayerItem status failed: \(errMsg)")
                    self?.playbackFailed = true
                    self?.playbackErrorMessage = errMsg
                } else if item.status == .readyToPlay {
                    self?.playbackFailed = false
                    self?.playbackErrorMessage = nil
                }
            }
        }

        player.replaceCurrentItem(with: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = isMuted
        player.actionAtItemEnd = .none

        ensureTimeObserver()
    }

    func cleanup() {
        stopDisplayLink()
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        if let token = statusObserverToken {
            token.invalidate()
            statusObserverToken = nil
        }
        player.pause()
        player.rate = 0.0
        isPlaying = false
    }

    func pause() {
        stopDisplayLink()
        player.pause()
        player.rate = 0.0
        isPlaying = false
    }

    func transitionTo(
        url: URL,
        startMs: Int64 = 0,
        inMs: Int64? = nil,
        outMs: Int64? = nil,
        playRate: Float = 1.0,
        autoPlay: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        ensureTimeObserver()
        didReachEndTime = false
        if let inMs = inMs { self.trimInMs = max(0, inMs) }
        if let outMs = outMs { self.trimOutMs = max(self.trimInMs + 50, outMs) }

        let safeRate = max(0.01, playRate)
        let effectiveStartMs = max(self.trimInMs, startMs)
        let targetSec = Double(effectiveStartMs) / 1000.0
        let targetCm = CMTime(seconds: targetSec, preferredTimescale: 60000)

        // Case A: Same source asset (e.g. split clip, trimmed segment, duplicate) - zero latency seek
        if (player.currentItem?.asset as? AVURLAsset)?.url == url, let curItem = player.currentItem {
            let outSec = Double(self.trimOutMs) / 1000.0
            curItem.forwardPlaybackEndTime = CMTime(seconds: outSec, preferredTimescale: 60000)
            player.seek(to: targetCm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self = self else { return }
                self.currentPositionTime = targetCm
                self.currentPositionMs = effectiveStartMs
                if autoPlay {
                    self.player.playImmediately(atRate: safeRate)
                    self.isPlaying = true
                    self.startDisplayLink()
                }
                completion?()
            }
            return
        }

        // Case B: Different source asset -> reuse existing AVPlayer with replaceCurrentItem (never destroy AVPlayerLayer)
        let playerItem = AVPlayerItem(url: url)
        playerItem.audioTimePitchAlgorithm = .timeDomain
        let outSec = Double(self.trimOutMs) / 1000.0
        playerItem.forwardPlaybackEndTime = CMTime(seconds: outSec, preferredTimescale: 60000)

        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.didReachEndTime = true
            if self.loopOnEnd {
                self.seek(to: self.trimInMs) {
                    self.play()
                }
            } else if self.isPlaying {
                self.stopDisplayLink()
                self.periodicTickHandler?(self.trimOutMs)
            }
        }

        player.replaceCurrentItem(with: playerItem)

        player.seek(to: targetCm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.currentPositionTime = targetCm
            self.currentPositionMs = effectiveStartMs
            if autoPlay {
                self.player.playImmediately(atRate: safeRate)
                self.isPlaying = true
                self.startDisplayLink()
            }
            completion?()
        }
    }

    func play(rate: Float = 1.0) {
        configureAudioSession()
        ensureTimeObserver()
        let safeRate = max(0.01, rate)
        applyPlaybackBounds()

        let curSec = CMTimeGetSeconds(player.currentTime())
        let curMs = Int64(round(curSec * 1000.0))

        // If currently at or past the trimmed out boundary, wrap to in-point
        if curMs >= trimOutMs - 35 || curMs < trimInMs - 50 {
            seek(to: trimInMs, preservePlaybackState: true) { [weak self] in
                guard let self = self else { return }
                self.player.playImmediately(atRate: safeRate)
                self.isPlaying = true
                self.startDisplayLink()
            }
            return
        }

        player.playImmediately(atRate: safeRate)
        isPlaying = true
        startDisplayLink()
    }

    // MARK: - Hardware V-Sync Display Link for Continuous 60/120Hz Animation
    func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLinkTick(_ link: CADisplayLink) {
        guard isPlaying else { return }
        let currentTime = player.currentTime()
        guard currentTime.isValid && !currentTime.isIndefinite else { return }
        let sec = CMTimeGetSeconds(currentTime)
        guard sec >= 0 else { return }
        onDisplayFrame?(sec)
    }

    func setRate(_ rate: Float) {
        if isPlaying {
            player.rate = max(0.01, rate)
        }
    }

    func togglePlayPause(rate: Float = 1.0) {
        if isPlaying {
            pause()
        } else {
            play(rate: rate)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func triggerHaptic() {
        hapticFeedback.prepare()
        hapticFeedback.impactOccurred()
    }

    func step(byCount count: Int, fps: Double, durationMs: Int64 = 0, completion: (() -> Void)? = nil) {
        pause()
        triggerHaptic()

        let safeFps = max(1.0, fps)
        let currentSec = CMTimeGetSeconds(player.currentTime())
        let currentFrameIndex = Int64(round(currentSec * safeFps))
        let targetFrameIndex = max(0, currentFrameIndex + Int64(count))
        let targetSec = Double(targetFrameIndex) / safeFps
        let targetCm = CMTime(seconds: targetSec, preferredTimescale: 60000)

        player.seek(to: targetCm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.pause()
            self.currentPositionTime = targetCm
            self.currentPositionMs = Int64(round(targetSec * 1000.0))
            completion?()
        }
    }

    func seek(to ms: Int64, preservePlaybackState: Bool = false, completion: (() -> Void)? = nil) {
        let wasPlaying = isPlaying
        let activeRate = player.rate
        if !preservePlaybackState {
            pause()
        }
        let targetSec = Double(ms) / 1000.0
        let cmTime = CMTime(seconds: targetSec, preferredTimescale: 60000)
        self.currentPositionTime = cmTime
        self.currentPositionMs = ms

        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.currentPositionTime = cmTime
            self.currentPositionMs = ms
            if preservePlaybackState && wasPlaying {
                self.player.rate = (activeRate > 0) ? activeRate : 1.0
                self.isPlaying = true
            } else if !preservePlaybackState {
                self.pause()
            }
            completion?()
        }
    }

    func seek(to cmTime: CMTime, completion: (() -> Void)? = nil) {
        pause()
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.pause()
            self.currentPositionTime = cmTime
            self.currentPositionMs = Int64(round(CMTimeGetSeconds(cmTime) * 1000.0))
            completion?()
        }
    }

    func seekToFrame(frameIndex: Int64, fps: Double, completion: (() -> Void)? = nil) {
        pause()
        let safeFps = max(1.0, fps)
        let targetSec = Double(max(0, frameIndex)) / safeFps
        let targetCm = CMTime(seconds: targetSec, preferredTimescale: 60000)
        player.seek(to: targetCm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.pause()
            self.currentPositionTime = targetCm
            self.currentPositionMs = Int64(round(targetSec * 1000.0))
            completion?()
        }
    }

    func currentFrameIndex(fps: Double) -> Int64 {
        let safeFps = max(1.0, fps)
        let sec = CMTimeGetSeconds(currentPositionTime)
        guard sec.isFinite && !sec.isNaN && sec >= 0 else { return 0 }
        return Int64(round(sec * safeFps))
    }

    func smpteTimecode(fps: Double) -> String {
        return formatToSMPTETimecode(seconds: CMTimeGetSeconds(currentPositionTime), fps: fps)
    }

    deinit {
        cleanup()
    }
}
