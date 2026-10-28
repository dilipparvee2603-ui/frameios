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

        let interval = CMTime(value: 1, timescale: 30) // ~30 FPS
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let ms = Int64(CMTimeGetSeconds(time) * 1000)
            self.currentPositionMs = ms
            onTick?(ms)
        }
    }

    func cleanup() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func seek(to ms: Int64, completion: (() -> Void)? = nil) {
        currentPositionMs = ms
        let cmTime = CMTime(value: CMTimeValue(ms), timescale: 1000)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            completion?()
        }
    }

    deinit {
        cleanup()
    }
}
