import Foundation
import AVFoundation

// MARK: - Native iOS Audio Waveform Extractor (LibreCuts Architecture)
/// Decodes the underlying audio track into normalized peak amplitude samples (0.0 ... 1.0)
/// for high-fidelity timeline waveform visualization.
final class AudioWaveformExtractor {
    static let shared = AudioWaveformExtractor()

    private let cache = NSCache<NSString, NSArray>()
    private let queue = DispatchQueue(label: "com.cfx.framestudio.waveform", qos: .userInitiated)

    private init() {
        cache.countLimit = 50
    }

    func cacheKey(url: URL, samples: Int) -> NSString {
        "\(url.absoluteString)_\(samples)" as NSString
    }

    /// Retrieve already-extracted waveform from cache if available
    func cachedWaveform(url: URL, samples: Int = 300) -> [Float]? {
        if let cached = cache.object(forKey: cacheKey(url: url, samples: samples)) as? [NSNumber] {
            return cached.map { $0.floatValue }
        }
        return nil
    }

    /// Extracts normalized amplitude points asynchronously from media audio track
    func extractWaveform(
        for url: URL,
        targetSamples: Int = 300,
        completion: @escaping ([Float]) -> Void
    ) {
        if let cached = cachedWaveform(url: url, samples: targetSamples) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }

            let asset = AVURLAsset(url: url)
            guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            do {
                let reader = try AVAssetReader(asset: asset)
                
                // Read 16-bit linear PCM, mono, 8000Hz for ultra-fast waveform extraction
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 8000
                ]

                let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
                trackOutput.alwaysCopiesSampleData = false
                reader.add(trackOutput)

                guard reader.startReading() else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }

                var pcmData = Data()
                while reader.status == .reading {
                    guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
                    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                    let length = CMBlockBufferGetDataLength(blockBuffer)
                    guard length > 0 else { continue }

                    var tempBytes = [UInt8](repeating: 0, count: length)
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &tempBytes)
                    pcmData.append(contentsOf: tempBytes)
                }

                guard !pcmData.isEmpty else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }

                // Process 16-bit signed PCM amplitudes
                let totalSamples = pcmData.count / 2
                guard totalSamples > 0 else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }

                let samplesPerBucket = max(1, totalSamples / targetSamples)
                var amplitudes = [Float](repeating: 0.0, count: targetSamples)
                var maxGlobalPeak: Float = 0.0

                pcmData.withUnsafeBytes { rawBuffer in
                    guard let int16Pointer = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }

                    for i in 0..<targetSamples {
                        let start = i * samplesPerBucket
                        let end = min(start + samplesPerBucket, totalSamples)
                        var localPeak: Float = 0.0

                        for j in start..<end {
                            let sampleVal = abs(Float(int16Pointer[j]))
                            if sampleVal > localPeak {
                                localPeak = sampleVal
                            }
                        }

                        amplitudes[i] = localPeak
                        if localPeak > maxGlobalPeak {
                            maxGlobalPeak = localPeak
                        }
                    }
                }

                // Normalize from 0.0 to 1.0
                if maxGlobalPeak > 0 {
                    for i in 0..<targetSamples {
                        amplitudes[i] = amplitudes[i] / maxGlobalPeak
                    }
                }

                // Cache result
                let nsNumbers = amplitudes.map { NSNumber(value: $0) }
                self.cache.setObject(nsNumbers as NSArray, forKey: self.cacheKey(url: url, samples: targetSamples))

                DispatchQueue.main.async {
                    completion(amplitudes)
                }

            } catch {
                DispatchQueue.main.async { completion([]) }
            }
        }
    }
}
