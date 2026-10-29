import Foundation
import AVFoundation
import ffmpegkit

// MARK: - Audio Export Format
enum AudioExportFormat: String, CaseIterable, Identifiable {
    case m4a = "M4A (Lossless Copy • 0% Loss)"
    case mp3 = "MP3 (320 kbps Studio)"
    case wav = "WAV (24-bit PCM Uncompressed)"
    case alac = "ALAC (Apple Lossless)"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .wav: return "wav"
        case .alac: return "m4a"
        }
    }

    var shortName: String {
        switch self {
        case .m4a: return "M4A Lossless"
        case .mp3: return "MP3 320k"
        case .wav: return "WAV 24-bit"
        case .alac: return "ALAC"
        }
    }
}

// MARK: - Audio Track Metadata
struct AudioTrackInfo {
    let codecName: String
    let sampleRate: Int
    let channels: Int
    let bitrate: Int64
    let durationSeconds: Double

    var sampleRateFormatted: String {
        let khz = Double(sampleRate) / 1000.0
        return String(format: "%.1f kHz", khz)
    }

    var channelsFormatted: String {
        switch channels {
        case 1: return "Mono 1.0"
        case 2: return "Stereo 2.0"
        case 6: return "Surround 5.1"
        case 8: return "Surround 7.1"
        default: return "\(channels) Ch"
        }
    }
}

// MARK: - Extract Result
struct AudioExtractResult {
    let success: Bool
    let outputUrl: URL?
    let errorMessage: String?
    let durationSeconds: Double
}

// MARK: - Audio Extract Engine
final class AudioExtractEngine {
    static let shared = AudioExtractEngine()

    private init() {}

    func cancel() {
        FFmpegKit.cancel()
    }

    // Probe audio track info
    func inspectAudioTrack(url: URL) async -> AudioTrackInfo? {
        do {
            let asset = AVURLAsset(url: url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = audioTracks.first else { return nil }

            let duration = try await asset.load(.duration)
            let durationSec = CMTimeGetSeconds(duration)

            var sampleRate = 48000
            var channels = 2
            var codecName = "AAC"

            if let descriptions = try? await track.load(.formatDescriptions), let first = descriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)
                if let asbd = asbd?.pointee {
                    sampleRate = Int(asbd.mSampleRate)
                    channels = Int(asbd.mChannelsPerFrame)
                }

                let subType = CMFormatDescriptionGetMediaSubType(first)
                codecName = fourCharCodeToString(subType).uppercased()
            }

            var bitrate: Int64 = 256000
            if let estRate = try? await track.load(.estimatedDataRate), estRate > 0 {
                bitrate = Int64(estRate)
            }

            return AudioTrackInfo(
                codecName: codecName,
                sampleRate: sampleRate,
                channels: channels,
                bitrate: bitrate,
                durationSeconds: durationSec
            )
        } catch {
            return nil
        }
    }

    // Extract Audio
    func extractAudio(
        srcUrl: URL,
        format: AudioExportFormat,
        startMs: Int64 = 0,
        endMs: Int64 = 0,
        onProgress: @escaping (Float) -> Void
    ) async -> AudioExtractResult {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let outputUrl = tempDir.appendingPathComponent("CFX_Audio_\(timestamp).\(format.fileExtension)")

        // Remove old if exists
        try? FileManager.default.removeItem(at: outputUrl)

        let asset = AVURLAsset(url: srcUrl)
        let totalDuration = (try? await asset.load(.duration)) ?? .zero
        let totalSec = CMTimeGetSeconds(totalDuration)

        let clampedStartMs = max(0, startMs)
        let clampedEndMs = (endMs > clampedStartMs) ? endMs : Int64(totalSec * 1000)

        let startSec = Double(clampedStartMs) / 1000.0
        let targetDuration = max(0.1, Double(clampedEndMs - clampedStartMs) / 1000.0)

        var args: [String] = []

        // Accurate seek
        if clampedStartMs > 0 {
            args += ["-ss", String(format: "%.3f", startSec)]
        }

        args += ["-i", srcUrl.path]

        if clampedEndMs > clampedStartMs {
            args += ["-t", String(format: "%.3f", targetDuration)]
        }

        // Drop video completely
        args += ["-vn"]

        // Format-specific encoding
        switch format {
        case .m4a:
            // Attempt stream-copy first for 0% loss
            args += ["-c:a", "copy"]
        case .mp3:
            args += ["-c:a", "libmp3lame", "-b:a", "320k", "-q:a", "0"]
        case .wav:
            args += ["-c:a", "pcm_s24le"]
        case .alac:
            args += ["-c:a", "alac"]
        }

        args += ["-y", outputUrl.path]

        // Enable progress callback
        FFmpegKitConfig.enableStatisticsCallback { stats in
            guard let stats = stats else { return }
            let timeInMs = stats.getTime()
            if targetDuration > 0 {
                let progress = min(1.0, max(0.0, Float(Double(timeInMs) / (targetDuration * 1000.0))))
                DispatchQueue.main.async {
                    onProgress(progress)
                }
            }
        }

        let session = FFmpegKit.execute(withArguments: args)
        FFmpegKitConfig.enableStatisticsCallback(nil)

        guard let returnCode = session?.getReturnCode() else {
            return AudioExtractResult(success: false, outputUrl: nil, errorMessage: "Execution failed", durationSeconds: 0)
        }

        if returnCode.isValueSuccess() && FileManager.default.fileExists(atPath: outputUrl.path) {
            return AudioExtractResult(success: true, outputUrl: outputUrl, errorMessage: nil, durationSeconds: targetDuration)
        } else {
            // If .m4a stream copy failed (e.g. source was Opus/AC3 incompatible with M4A container), transcode to AAC 320k
            if format == .m4a {
                var fallbackArgs: [String] = []
                if clampedStartMs > 0 {
                    fallbackArgs += ["-ss", String(format: "%.3f", startSec)]
                }
                fallbackArgs += ["-i", srcUrl.path]
                if clampedEndMs > clampedStartMs {
                    fallbackArgs += ["-t", String(format: "%.3f", targetDuration)]
                }
                fallbackArgs += ["-vn", "-c:a", "aac", "-b:a", "320k", "-y", outputUrl.path]

                let fbSession = FFmpegKit.execute(withArguments: fallbackArgs)
                if let fbCode = fbSession?.getReturnCode(), fbCode.isValueSuccess() && FileManager.default.fileExists(atPath: outputUrl.path) {
                    return AudioExtractResult(success: true, outputUrl: outputUrl, errorMessage: nil, durationSeconds: targetDuration)
                }

                // Tier 3: Native AVAssetExportSession fallback (Apple AVFoundation hardware)
                if let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
                    exportSession.outputURL = outputUrl
                    exportSession.outputFileType = .m4a
                    if clampedEndMs > clampedStartMs {
                        let startTime = CMTime(seconds: startSec, preferredTimescale: 60000)
                        let duration = CMTime(seconds: targetDuration, preferredTimescale: 60000)
                        exportSession.timeRange = CMTimeRange(start: startTime, duration: duration)
                    }
                    await exportSession.export()
                    if exportSession.status == .completed && FileManager.default.fileExists(atPath: outputUrl.path) {
                        return AudioExtractResult(success: true, outputUrl: outputUrl, errorMessage: nil, durationSeconds: targetDuration)
                    }
                }
            }

            let logs = session?.getAllLogsAsString() ?? "Unknown error"
            AppLogger.shared.error(tag: "AUDIO_EXTRACT", message: logs)
            return AudioExtractResult(success: false, outputUrl: nil, errorMessage: logs, durationSeconds: 0)
        }
    }

    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        let bytes: [CChar] = [
            CChar((code >> 24) & 0xff),
            CChar((code >> 16) & 0xff),
            CChar((code >> 8) & 0xff),
            CChar(code & 0xff),
            0
        ]
        return String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
