import Foundation
import AVFoundation

final class PlayerModel: ObservableObject {
    @Published var player: AVPlayer = AVPlayer()
    @Published var isPlaying: Bool = false
    @Published var isMuted: Bool = false
    @Published var currentPositionMs: Int64 = 0

    private var timeObserverToken: Any? = nil

    func setup(with url: URL, onTick: ((Int64) -> Void)? = nil) {
        cleanup()
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause

        let interval = CMTime(value: 1, timescale: 30) // ~30 FPS UI sync
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if self.isPlaying {
                let ms = Int64(CMTimeGetSeconds(time) * 1000)
                self.currentPositionMs = ms
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

    func step(byCount count: Int, fps: Double, durationMs: Int64 = 0, completion: (() -> Void)? = nil) {
        pause()

        let safeFps = max(1.0, fps)
        let currentSec = CMTimeGetSeconds(player.currentTime())
        let currentFrameIndex = Int64(round(currentSec * safeFps))
        let targetFrameIndex = max(0, currentFrameIndex + Int64(count))
        let targetSec = Double(targetFrameIndex) / safeFps
        let targetCm = CMTime(seconds: targetSec, preferredTimescale: 60000)

        player.seek(to: targetCm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.pause()
            self.currentPositionMs = Int64(round(targetSec * 1000.0))
            completion?()
        }
    }

    func seek(to ms: Int64, completion: (() -> Void)? = nil) {
        pause()
        let cmTime = CMTime(value: CMTimeValue(ms), timescale: 1000)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.pause()
            self.currentPositionMs = ms
            completion?()
        }
    }

    deinit {
        cleanup()
    }
}
