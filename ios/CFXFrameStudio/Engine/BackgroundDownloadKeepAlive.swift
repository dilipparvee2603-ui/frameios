import Foundation
import AVFoundation
import UIKit

/// Manages background execution and audio keepalive to guarantee downloads continue
/// uninterrupted without "Network Connection Lost" errors when the user switches apps or locks their device.
final class BackgroundDownloadKeepAlive: NSObject, AVAudioPlayerDelegate {
    static let shared = BackgroundDownloadKeepAlive()

    private var audioPlayer: AVAudioPlayer?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var isKeepAliveActive: Bool = false
    private let queue = DispatchQueue(label: "com.cfx.backgroundKeepAlive", qos: .userInitiated)

    private override init() {
        super.init()
    }

    /// Activates inaudible background keepalive and registers a background task
    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isKeepAliveActive else { return }
            self.isKeepAliveActive = true

            self.beginBackgroundTask()
            self.startSilentAudioLoop()
        }
    }

    /// Stops keepalive and releases audio and background execution locks
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.isKeepAliveActive else { return }
            self.isKeepAliveActive = false

            self.stopSilentAudioLoop()
            self.endBackgroundTask()
        }
    }

    // MARK: - Silent Audio Loop

    private func startSilentAudioLoop() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Set playback with mixWithOthers so it never interrupts user's music, podcasts, or system audio
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)

            if audioPlayer == nil {
                let silentWav = createSilentWavData()
                audioPlayer = try AVAudioPlayer(data: silentWav)
                audioPlayer?.delegate = self
                audioPlayer?.numberOfLoops = -1 // Infinite loop
                audioPlayer?.volume = 0.001 // Virtually silent, keeping the hardware audio stream active for backgrounding
            }

            audioPlayer?.play()
        } catch {
            print("[BackgroundKeepAlive] Error activating audio keepalive: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudioLoop() {
        audioPlayer?.stop()
        audioPlayer = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Non-critical cleanup
        }
    }

    // MARK: - Background Task Identifier

    private func beginBackgroundTask() {
        endBackgroundTask()
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "CFX_ContinuousDownload") { [weak self] in
            guard let self = self else { return }
            // If iOS signals task expiration, refresh the task to give URLSession more time
            self.queue.async {
                self.beginBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }

    // MARK: - Synthesizes a valid 1-second silent PCM WAV file in memory

    private func createSilentWavData() -> Data {
        let sampleRate: Int32 = 8000
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let durationSeconds: Int32 = 1

        let dataSize = sampleRate * Int32(channels) * Int32(bitsPerSample / 8) * durationSeconds
        let fileSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: fileSize) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // "fmt " sub-chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        let subchunk1Size: Int32 = 16
        data.append(contentsOf: withUnsafeBytes(of: subchunk1Size) { Array($0) })
        let audioFormat: Int16 = 1 // PCM
        data.append(contentsOf: withUnsafeBytes(of: audioFormat) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: channels) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate) { Array($0) })
        let byteRate: Int32 = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: byteRate) { Array($0) })
        let blockAlign: Int16 = channels * (bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: blockAlign) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample) { Array($0) })

        // "data" sub-chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: dataSize) { Array($0) })

        // Zeroes (silence)
        data.append(Data(count: Int(dataSize)))

        return data
    }
}
