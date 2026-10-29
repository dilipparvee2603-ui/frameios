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
    var onDidPlayToEnd: (() -> Void)? = nil

    private var timeObserverToken: Any? = nil
    private var endObserverToken: Any? = nil
    private var statusObserverToken: NSKeyValueObservation? = nil
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .rigid)

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    func setup(with url: URL, onTick: ((Int64) -> Void)? = nil) {
        cleanup()
        configureAudioSession()

        let playerItem = AVPlayerItem(url: url)
        // High quality pitch algorithm prevents distortion during slow or retimed playback
        playerItem.audioTimePitchAlgorithm = .timeDomain
        player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = isMuted
        player.actionAtItemEnd = .none

        // Loop / reset or trigger continuous project playback
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let customHandler = self.onDidPlayToEnd {
                customHandler()
            } else {
                self.pause()
                self.seek(to: Int64(0))
            }
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

        let interval = CMTime(value: 1, timescale: 60) // 60Hz UI sync
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentPositionTime = time
            let ms = Int64(CMTimeGetSeconds(time) * 1000.0)
            self.currentPositionMs = ms
            if self.isPlaying {
                onTick?(ms)
            }
        }
    }

    func cleanup() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
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
        player.pause()
        player.rate = 0.0
        isPlaying = false
    }

    func play(rate: Float = 1.0) {
        configureAudioSession()
        let safeRate = max(0.01, rate)
        if let currentItem = player.currentItem, currentItem.duration.isValid {
            let dur = CMTimeGetSeconds(currentItem.duration)
            let cur = CMTimeGetSeconds(player.currentTime())
            if dur > 0 && cur >= dur - 0.05 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        player.playImmediately(atRate: safeRate)
        isPlaying = true
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
