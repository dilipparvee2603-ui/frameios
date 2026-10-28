import Foundation
import AVFoundation
import UIKit

final class PlayerModel: ObservableObject {
    @Published var player: AVPlayer = AVPlayer()
    @Published var isPlaying: Bool = false
    @Published var isMuted: Bool = false
    @Published var currentPositionMs: Int64 = 0
    @Published var currentPositionTime: CMTime = .zero

    private var timeObserverToken: Any? = nil
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .rigid)

    func setup(with url: URL, onTick: ((Int64) -> Void)? = nil) {
        cleanup()
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause

        // Prime decoder to display frame 0 immediately upon loading
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

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
        player.pause()
        player.rate = 0.0
        isPlaying = false
    }

    func pause() {
        player.pause()
        player.rate = 0.0
        isPlaying = false
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
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

    func seek(to ms: Int64, completion: (() -> Void)? = nil) {
        pause()
        let targetSec = Double(ms) / 1000.0
        let cmTime = CMTime(seconds: targetSec, preferredTimescale: 60000)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.pause()
            self.currentPositionTime = cmTime
            self.currentPositionMs = ms
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
