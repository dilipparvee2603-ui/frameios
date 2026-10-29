import Foundation
import AVFoundation

// MARK: - Audio Export Format
enum AudioExportFormat: String, CaseIterable, Identifiable {
    case m4aLossless = "M4A (Lossless Copy • 0% Loss)"
    case m4aStudio = "M4A (Studio 320 kbps AAC)"
    case wav = "WAV (24-bit PCM Uncompressed)"
    case alac = "ALAC (Apple Lossless Audio)"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .m4aLossless, .m4aStudio, .alac: return "m4a"
        case .wav: return "wav"
        }
    }

    var shortName: String {
        switch self {
        case .m4aLossless: return "M4A Lossless"
        case .m4aStudio: return "M4A 320k"
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

// MARK: - Audio Extract Engine (Native Apple Hardware Accelerated)
final class AudioExtractEngine {
    static let shared = AudioExtractEngine()

    private var currentExportSession: AVAssetExportSession?
    private var isCancelled: Bool = false

    private init() {}

    func cancel() {
        isCancelled = true
        currentExportSession?.cancelExport()
        currentExportSession = nil
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

    // Extract Audio using native AVFoundation
    func extractAudio(
        srcUrl: URL,
        format: AudioExportFormat,
        startMs: Int64 = 0,
        endMs: Int64 = 0,
        onProgress: @escaping (Float) -> Void
    ) async -> AudioExtractResult {
        isCancelled = false

        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let outputUrl = tempDir.appendingPathComponent("CFX_Audio_\(timestamp).\(format.fileExtension)")

        try? FileManager.default.removeItem(at: outputUrl)

        let asset = AVURLAsset(url: srcUrl)
        let totalDuration = (try? await asset.load(.duration)) ?? .zero
        let totalSec = CMTimeGetSeconds(totalDuration)

        let clampedStartMs = max(0, startMs)
        let clampedEndMs = (endMs > clampedStartMs) ? endMs : Int64(totalSec * 1000)

        let startSec = Double(clampedStartMs) / 1000.0
        let targetDuration = max(0.1, Double(clampedEndMs - clampedStartMs) / 1000.0)

        let timeRange: CMTimeRange?
        if clampedEndMs > clampedStartMs && clampedEndMs < Int64(totalSec * 1000) || clampedStartMs > 0 {
            let startTime = CMTime(seconds: startSec, preferredTimescale: 60000)
            let duration = CMTime(seconds: targetDuration, preferredTimescale: 60000)
            timeRange = CMTimeRange(start: startTime, duration: duration)
        } else {
            timeRange = nil
        }

        switch format {
        case .wav:
            // Extract via AVAssetReader + AVAssetWriter (24-bit PCM WAV)
            return await exportWavNative(
                asset: asset,
                outputUrl: outputUrl,
                timeRange: timeRange,
                targetDuration: targetDuration,
                onProgress: onProgress
            )

        case .m4aLossless:
            // Attempt Passthrough stream copy (0% quality loss) first
            if let passthroughSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
                currentExportSession = passthroughSession
                passthroughSession.outputURL = outputUrl
                passthroughSession.outputFileType = .m4a
                if let tr = timeRange { passthroughSession.timeRange = tr }

                let timer = startProgressTimer(session: passthroughSession, onProgress: onProgress)
                await passthroughSession.export()
                timer?.invalidate()

                if passthroughSession.status == .completed && FileManager.default.fileExists(atPath: outputUrl.path) {
                    AppLogger.shared.log(tag: "AUDIO_EXTRACT", message: "Extracted lossless M4A stream copy successfully")
                    return AudioExtractResult(success: true, outputUrl: outputUrl, errorMessage: nil, durationSeconds: targetDuration)
                }
            }

            // Fallback to Apple M4A preset
            return await exportWithPreset(
                asset: asset,
                preset: AVAssetExportPresetAppleM4A,
                outputUrl: outputUrl,
                timeRange: timeRange,
                targetDuration: targetDuration,
                onProgress: onProgress
            )

        case .m4aStudio, .alac:
            return await exportWithPreset(
                asset: asset,
                preset: AVAssetExportPresetAppleM4A,
                outputUrl: outputUrl,
                timeRange: timeRange,
                targetDuration: targetDuration,
                onProgress: onProgress
            )
        }
    }

    private func exportWithPreset(
        asset: AVAsset,
        preset: String,
        outputUrl: URL,
        timeRange: CMTimeRange?,
        targetDuration: Double,
        onProgress: @escaping (Float) -> Void
    ) async -> AudioExtractResult {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            let msg = "Could not create AVAssetExportSession with preset \(preset)"
            AppLogger.shared.error(tag: "AUDIO_EXTRACT", message: msg)
            return AudioExtractResult(success: false, outputUrl: nil, errorMessage: msg, durationSeconds: 0)
        }

        currentExportSession = session
        session.outputURL = outputUrl
        session.outputFileType = .m4a
        if let tr = timeRange { session.timeRange = tr }

        let timer = startProgressTimer(session: session, onProgress: onProgress)
        await session.export()
        timer?.invalidate()

        if session.status == .completed && FileManager.default.fileExists(atPath: outputUrl.path) {
            AppLogger.shared.log(tag: "AUDIO_EXTRACT", message: "Extracted M4A successfully")
            return AudioExtractResult(success: true, outputUrl: outputUrl, errorMessage: nil, durationSeconds: targetDuration)
        } else {
            let err = session.error?.localizedDescription ?? "Export session failed"
            AppLogger.shared.error(tag: "AUDIO_EXTRACT", message: err)
            return AudioExtractResult(success: false, outputUrl: nil, errorMessage: err, durationSeconds: 0)
        }
    }

    // Native uncompressed WAV exporter
    private func exportWavNative(
        asset: AVAsset,
        outputUrl: URL,
        timeRange: CMTimeRange?,
        targetDuration: Double,
        onProgress: @escaping (Float) -> Void
    ) async -> AudioExtractResult {
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = audioTracks.first else {
                let msg = "No audio track found in video"
                AppLogger.shared.error(tag: "AUDIO_EXTRACT", message: msg)
                return AudioExtractResult(success: false, outputUrl: nil, errorMessage: msg, durationSeconds: 0)
            }

            let reader = try AVAssetReader(asset: asset)
            if let tr = timeRange {
                reader.timeRange = tr
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]

            let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            readerOutput.alwaysCopiesSampleData = false
            reader.add(readerOutput)

            let writer = try AVAssetWriter(outputURL: outputUrl, fileType: .wav)
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            writerInput.expectsMediaDataInRealTime = false
            writer.add(writerInput)

            reader.startReading()
            writer.startWriting()
            writer.startSession(atSourceTime: timeRange?.start ?? .zero)

            await withCheckedContinuation { continuation in
                let queue = DispatchQueue(label: "cfx.audio.wav.writer")
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        if self.isCancelled {
                            reader.cancelReading()
                            writer.cancelWriting()
                            continuation.resume()
                            return
                        }

                        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                            writerInput.append(sampleBuffer)
                        } else {
                            writerInput.markAsFinished()
                            writer.finishWriting {
                                continuation.resume()
                            }
                            return
                        }
                    }
                }
            }

            if writer.status == .completed && FileManager.default.fileExists(atPath: outputUrl.path) {
                AppLogger.shared.log(tag: "AUDIO_EXTRACT", message: "Extracted 24-bit WAV successfully")
                return AudioExtractResult(success: true, outputUrl: outputUrl, errorMessage: nil, durationSeconds: targetDuration)
            } else {
                let err = writer.error?.localizedDescription ?? "WAV writing failed"
                AppLogger.shared.error(tag: "AUDIO_EXTRACT", message: err)
                return AudioExtractResult(success: false, outputUrl: nil, errorMessage: err, durationSeconds: 0)
            }
        } catch {
            let msg = error.localizedDescription
            AppLogger.shared.error(tag: "AUDIO_EXTRACT", message: msg)
            return AudioExtractResult(success: false, outputUrl: nil, errorMessage: msg, durationSeconds: 0)
        }
    }

    private func startProgressTimer(session: AVAssetExportSession, onProgress: @escaping (Float) -> Void) -> Timer? {
        return Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            DispatchQueue.main.async {
                onProgress(session.progress)
            }
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
