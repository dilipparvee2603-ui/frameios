import Foundation
import SwiftUI
import AVFoundation

// MARK: - Canvas & Aspect Ratio
enum AspectRatioPreset: String, CaseIterable, Identifiable, Codable {
    case ratio16x9 = "16:9 (Landscape / YouTube)"
    case ratio9x16 = "9:16 (Vertical / Reels & TikTok)"
    case ratio1x1 = "1:1 (Square / Feed)"
    case ratio4x5 = "4:5 (Portrait / Instagram)"
    case original = "Original Media Aspect"

    var id: String { rawValue }

    var badgeText: String {
        switch self {
        case .ratio16x9: return "16:9"
        case .ratio9x16: return "9:16"
        case .ratio1x1: return "1:1"
        case .ratio4x5: return "4:5"
        case .original: return "AUTO"
        }
    }

    var ratioValue: CGFloat? {
        switch self {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio9x16: return 9.0 / 16.0
        case .ratio1x1: return 1.0
        case .ratio4x5: return 4.0 / 5.0
        case .original: return nil
        }
    }

    func renderDimensions(baseWidth: CGFloat = 1080) -> CGSize {
        switch self {
        case .ratio16x9: return CGSize(width: 1920, height: 1080)
        case .ratio9x16: return CGSize(width: 1080, height: 1920)
        case .ratio1x1: return CGSize(width: 1080, height: 1080)
        case .ratio4x5: return CGSize(width: 1080, height: 1350)
        case .original: return CGSize(width: 1080, height: 1920)
        }
    }
}

// MARK: - Transform & Fit Geometry
enum FitMode: String, CaseIterable, Identifiable, Codable {
    case fit = "Fit (Letterbox)"
    case fill = "Fill (Crop)"
    var id: String { rawValue }
}

enum RotationAngle: Int, CaseIterable, Identifiable, Codable {
    case r0 = 0
    case r90 = 90
    case r180 = 180
    case r270 = 270

    var id: Int { rawValue }

    var radians: Double {
        Double(rawValue) * .pi / 180.0
    }

    var next: RotationAngle {
        switch self {
        case .r0: return .r90
        case .r90: return .r180
        case .r180: return .r270
        case .r270: return .r0
        }
    }
}

struct TransformGeometry: Codable, Equatable {
    var rotation: RotationAngle = .r0
    var flipH: Bool = false
    var flipV: Bool = false
    var scale: Double = 1.0
    var offsetX: Double = 0.0
    var offsetY: Double = 0.0
    var fitMode: FitMode = .fit

    static let identity = TransformGeometry()
}

// MARK: - Core Image Color Adjustments
struct ColorAdjustments: Codable, Equatable {
    var brightness: Double = 0.0      // -1.0 to 1.0 (default 0.0)
    var contrast: Double = 1.0        // 0.0 to 2.0 (default 1.0)
    var saturation: Double = 1.0      // 0.0 to 2.0 (default 1.0)
    var exposure: Double = 0.0        // -2.0 to 2.0 (default 0.0)
    var temperature: Double = 6500.0  // Kelvin: 2000 to 10000 (default 6500)
    var tint: Double = 0.0            // -100 to 100 (default 0)

    static let identity = ColorAdjustments()

    var isDefault: Bool {
        brightness == 0.0 &&
        contrast == 1.0 &&
        saturation == 1.0 &&
        exposure == 0.0 &&
        temperature == 6500.0 &&
        tint == 0.0
    }
}

// MARK: - Keyframe Animation System
enum KeyframeProperty: String, CaseIterable, Identifiable, Codable {
    case positionX = "Position X"
    case positionY = "Position Y"
    case scale = "Zoom / Scale"
    case rotation = "Rotation"
    case opacity = "Opacity"
    case brightness = "Brightness"
    case contrast = "Contrast"
    case saturation = "Saturation"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .positionX, .positionY: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scale: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .rotation: return "rotate.right"
        case .opacity: return "circle.lefthalf.filled"
        case .brightness: return "sun.max.fill"
        case .contrast: return "circle.righthalf.filled"
        case .saturation: return "paintpalette.fill"
        }
    }

    var defaultVal: Double {
        switch self {
        case .positionX, .positionY: return 0.0
        case .scale: return 1.0
        case .rotation: return 0.0
        case .opacity: return 1.0
        case .brightness: return 0.0
        case .contrast: return 1.0
        case .saturation: return 1.0
        }
    }
}

enum KeyframeEasing: String, CaseIterable, Identifiable, Codable {
    case linear = "Linear"
    case easeIn = "Ease In"
    case easeOut = "Ease Out"
    case easeInOut = "Ease In-Out"
    case smooth = "Smooth"

    var id: String { rawValue }

    func interpolate(from v0: Double, to v1: Double, progress t: Double) -> Double {
        let clampedT = max(0.0, min(1.0, t))
        let easedT: Double
        switch self {
        case .linear:
            easedT = clampedT
        case .easeIn:
            easedT = clampedT * clampedT
        case .easeOut:
            easedT = clampedT * (2.0 - clampedT)
        case .easeInOut:
            easedT = clampedT < 0.5 ? 2.0 * clampedT * clampedT : -1.0 + (4.0 - 2.0 * clampedT) * clampedT
        case .smooth:
            easedT = (1.0 - cos(clampedT * .pi)) / 2.0
        }
        return v0 + (v1 - v0) * easedT
    }
}

struct ClipKeyframe: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var timeMs: Int64              // Clip-local presentation timestamp in ms (0 ... clip.timelineDurationMs)
    var property: KeyframeProperty
    var value: Double
    var easing: KeyframeEasing = .easeInOut
}

// MARK: - Transitions
enum TransitionType: String, CaseIterable, Identifiable, Codable {
    case cut = "Direct Cut"
    case crossDissolve = "Cross Dissolve"
    case fadeBlack = "Fade to Black"
    case fadeWhite = "Fade to White"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cut: return "scissors"
        case .crossDissolve: return "slider.horizontal.below.rectangle"
        case .fadeBlack: return "moon.fill"
        case .fadeWhite: return "sun.max.fill"
        }
    }
}

// MARK: - Speed Ramp Keyframe Point
struct SpeedRampPoint: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var normalizedPosition: Double // 0.0 to 1.0 along the clip's trimmed source duration
    var speedMultiplier: Double    // 0.10 to 2.0 (e.g. 0.25 = 4x slow-mo, 1.0 = normal)
}

// MARK: - Clip Speed Configuration
struct ClipSpeedConfiguration: Codable, Equatable {
    var speedMultiplier: Double = 1.0 // 0.10 (10x slow-mo) to 2.0 (2x fast)
    var isRamp: Bool = false
    var rampPoints: [SpeedRampPoint] = [
        SpeedRampPoint(normalizedPosition: 0.0, speedMultiplier: 1.0),
        SpeedRampPoint(normalizedPosition: 0.35, speedMultiplier: 0.25),
        SpeedRampPoint(normalizedPosition: 0.65, speedMultiplier: 0.25),
        SpeedRampPoint(normalizedPosition: 1.0, speedMultiplier: 1.0)
    ]
    var interpolationMode: SlowMoInterpolationMode = .opticalFlow
    var audioMode: SlowMoAudioMode = .pitchPreserved

    /// Evaluate speed multiplier at any normalized source progress (0.0 ... 1.0)
    func evaluateSpeed(at progress: Double) -> Double {
        guard isRamp, rampPoints.count >= 2 else {
            return max(0.10, speedMultiplier)
        }

        let sorted = rampPoints.sorted { $0.normalizedPosition < $1.normalizedPosition }
        let clamped = max(0.0, min(1.0, progress))

        if clamped <= sorted.first!.normalizedPosition {
            return sorted.first!.speedMultiplier
        }
        if clamped >= sorted.last!.normalizedPosition {
            return sorted.last!.speedMultiplier
        }

        for i in 0..<(sorted.count - 1) {
            let p0 = sorted[i]
            let p1 = sorted[i + 1]
            if clamped >= p0.normalizedPosition && clamped <= p1.normalizedPosition {
                let span = p1.normalizedPosition - p0.normalizedPosition
                guard span > 0.0001 else { return p0.speedMultiplier }
                let t = (clamped - p0.normalizedPosition) / span
                // Smooth cosine / hermite ease interpolation
                let smoothT = (1.0 - cos(t * .pi)) / 2.0
                return p0.speedMultiplier + (p1.speedMultiplier - p0.speedMultiplier) * smoothT
            }
        }
        return speedMultiplier
    }
}

// MARK: - Editor Clip Model (Non-Destructive)
struct EditorClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var sourceUrl: URL
    var filename: String
    var sourceDurationMs: Int64
    var sourceInPointMs: Int64
    var sourceOutPointMs: Int64

    var speedConfig: ClipSpeedConfiguration = ClipSpeedConfiguration()
    var transform: TransformGeometry = TransformGeometry()
    var color: ColorAdjustments = ColorAdjustments()

    var keyframes: [ClipKeyframe] = []

    var volume: Double = 1.0 // 0.0 to 2.0
    var isMuted: Bool = false

    var transitionOut: TransitionType = .cut
    var transitionDurationMs: Int64 = 500

    // MARK: - Keyframe Animation Evaluation
    func keyframes(for property: KeyframeProperty) -> [ClipKeyframe] {
        keyframes.filter { $0.property == property }.sorted { $0.timeMs < $1.timeMs }
    }

    func hasKeyframes(for property: KeyframeProperty? = nil) -> Bool {
        if let p = property {
            return keyframes.contains { $0.property == p }
        }
        return !keyframes.isEmpty
    }

    /// Evaluates property value at clip-local presentation timestamp in ms
    func evaluate(property: KeyframeProperty, at timeMs: Int64, defaultValue: Double) -> Double {
        let propertyKeyframes = keyframes(for: property)
        guard !propertyKeyframes.isEmpty else { return defaultValue }

        let clampedTime = max(0, min(timelineDurationMs, timeMs))
        if clampedTime <= propertyKeyframes.first!.timeMs {
            return propertyKeyframes.first!.value
        }
        if clampedTime >= propertyKeyframes.last!.timeMs {
            return propertyKeyframes.last!.value
        }

        for i in 0..<(propertyKeyframes.count - 1) {
            let k0 = propertyKeyframes[i]
            let k1 = propertyKeyframes[i + 1]
            if clampedTime >= k0.timeMs && clampedTime <= k1.timeMs {
                let span = Double(k1.timeMs - k0.timeMs)
                guard span > 0.001 else { return k0.value }
                let t = Double(clampedTime - k0.timeMs) / span
                return k0.easing.interpolate(from: k0.value, to: k1.value, progress: t)
            }
        }
        return defaultValue
    }

    /// Evaluates all dynamic transform parameters at a clip-local presentation time (ms)
    func evaluatedTransform(at timeMs: Int64) -> (scale: Double, offsetX: Double, offsetY: Double, rotationDegrees: Double, opacity: Double) {
        let scaleVal = evaluate(property: .scale, at: timeMs, defaultValue: transform.scale)
        let offX = evaluate(property: .positionX, at: timeMs, defaultValue: transform.offsetX)
        let offY = evaluate(property: .positionY, at: timeMs, defaultValue: transform.offsetY)
        let rot = evaluate(property: .rotation, at: timeMs, defaultValue: Double(transform.rotation.rawValue))
        let op = evaluate(property: .opacity, at: timeMs, defaultValue: 1.0)
        return (max(0.1, scaleVal), offX, offY, rot, max(0.0, min(1.0, op)))
    }

    /// Evaluates color adjustments at a clip-local presentation time (ms)
    func evaluatedColor(at timeMs: Int64) -> ColorAdjustments {
        var adj = color
        adj.brightness = evaluate(property: .brightness, at: timeMs, defaultValue: color.brightness)
        adj.contrast = evaluate(property: .contrast, at: timeMs, defaultValue: color.contrast)
        adj.saturation = evaluate(property: .saturation, at: timeMs, defaultValue: color.saturation)
        return adj
    }

    /// Adds or updates a keyframe for the specified property at the given clip-local timestamp
    mutating func addOrUpdateKeyframe(property: KeyframeProperty, timeMs: Int64, value: Double, easing: KeyframeEasing = .easeInOut) {
        let clampedTime = max(0, min(timelineDurationMs, timeMs))
        if let existingIdx = keyframes.firstIndex(where: { $0.property == property && abs($0.timeMs - clampedTime) <= 40 }) {
            keyframes[existingIdx].value = value
            keyframes[existingIdx].timeMs = clampedTime
            keyframes[existingIdx].easing = easing
        } else {
            keyframes.append(ClipKeyframe(timeMs: clampedTime, property: property, value: value, easing: easing))
            keyframes.sort { $0.timeMs < $1.timeMs }
        }
    }

    /// Removes keyframe for property near specified timestamp
    mutating func removeKeyframe(property: KeyframeProperty, timeMs: Int64, toleranceMs: Int64 = 60) {
        keyframes.removeAll { $0.property == property && abs($0.timeMs - timeMs) <= toleranceMs }
    }

    /// Retrieves keyframe for property near specified timestamp
    func keyframe(property: KeyframeProperty, near timeMs: Int64, toleranceMs: Int64 = 60) -> ClipKeyframe? {
        keyframes.first { $0.property == property && abs($0.timeMs - timeMs) <= toleranceMs }
    }

    /// Previous keyframe timestamp before given time
    func previousKeyframeTime(from timeMs: Int64, property: KeyframeProperty? = nil) -> Int64? {
        let list = (property != nil ? keyframes(for: property!) : keyframes.sorted { $0.timeMs < $1.timeMs })
        return list.filter { $0.timeMs < timeMs - 40 }.last?.timeMs
    }

    /// Next keyframe timestamp after given time
    func nextKeyframeTime(from timeMs: Int64, property: KeyframeProperty? = nil) -> Int64? {
        let list = (property != nil ? keyframes(for: property!) : keyframes.sorted { $0.timeMs < $1.timeMs })
        return list.filter { $0.timeMs > timeMs + 40 }.first?.timeMs
    }

    /// All unique keyframe timestamps on this clip
    func allKeyframeTimes() -> [Int64] {
        Array(Set(keyframes.map { $0.timeMs })).sorted()
    }

    // MARK: - Computed Durations
    /// Raw un-stretched source media trimmed duration in ms
    var sourceTrimmedDurationMs: Int64 {
        max(50, sourceOutPointMs - sourceInPointMs)
    }

    /// Effective timeline duration after speed retiming in ms
    var timelineDurationMs: Int64 {
        if !speedConfig.isRamp {
            let speed = max(0.05, speedConfig.speedMultiplier)
            return Int64(round(Double(sourceTrimmedDurationMs) / speed))
        } else {
            // Numerically integrate 1 / speed(t) dt across 20 segments
            let samples = 20
            var sumTimeFactor = 0.0
            for i in 0..<samples {
                let normT = (Double(i) + 0.5) / Double(samples)
                let s = speedConfig.evaluateSpeed(at: normT)
                sumTimeFactor += (1.0 / max(0.05, s))
            }
            let avgFactor = sumTimeFactor / Double(samples)
            return Int64(round(Double(sourceTrimmedDurationMs) * avgFactor))
        }
    }

    /// Maps a millisecond offset within this clip on the timeline to the corresponding source media timestamp (ms)
    func mapTimelineOffsetToSourceMs(_ offsetMs: Int64) -> Int64 {
        let clampedOffset = max(0, min(timelineDurationMs, offsetMs))
        let progress = timelineDurationMs > 0 ? (Double(clampedOffset) / Double(timelineDurationMs)) : 0.0

        if !speedConfig.isRamp {
            let sourceDeltaMs = Int64(round(Double(clampedOffset) * speedConfig.speedMultiplier))
            return min(sourceOutPointMs, max(sourceInPointMs, sourceInPointMs + sourceDeltaMs))
        } else {
            // Linear approximation for ramp progress
            let sourceDeltaMs = Int64(round(progress * Double(sourceTrimmedDurationMs)))
            return min(sourceOutPointMs, max(sourceInPointMs, sourceInPointMs + sourceDeltaMs))
        }
    }

    /// Maps a source timestamp (ms) back to this clip's timeline offset (ms)
    func mapSourceMsToTimelineOffset(_ srcMs: Int64) -> Int64 {
        let deltaSrc = max(0, min(sourceTrimmedDurationMs, srcMs - sourceInPointMs))
        let progress = sourceTrimmedDurationMs > 0 ? (Double(deltaSrc) / Double(sourceTrimmedDurationMs)) : 0.0
        return Int64(round(progress * Double(timelineDurationMs)))
    }
}

// MARK: - Secondary Audio Track
struct EditorAudioTrack: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var url: URL
    var title: String
    var timelineStartMs: Int64 = 0
    var durationMs: Int64
    var volume: Double = 1.0
    var isMuted: Bool = false
    var fadeInMs: Int64 = 0
    var fadeOutMs: Int64 = 0
}

// MARK: - Text / Graphic Overlay
struct EditorTextOverlay: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String = "Title Text"
    var fontName: String = "HelveticaNeue-Bold"
    var fontSize: CGFloat = 36.0
    var textColorHex: String = "FFFFFF"
    var backgroundColorHex: String? = nil
    var alignment: String = "center" // left, center, right
    var timelineStartMs: Int64 = 0
    var timelineEndMs: Int64 = 3000
    var posX: Double = 0.5 // 0.0 to 1.0 normalized screen coordinate
    var posY: Double = 0.8 // 0.0 to 1.0
    var scale: Double = 1.0
}

// MARK: - Master Video Project Model
struct VideoProject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String = "New Project"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var canvasAspectRatio: AspectRatioPreset = .ratio9x16
    var targetFps: Int = 30

    var clips: [EditorClip] = []
    var audioTracks: [EditorAudioTrack] = []
    var textOverlays: [EditorTextOverlay] = []

    // MARK: - Project Timeline Computations
    /// Total duration of the project timeline in milliseconds
    var totalTimelineDurationMs: Int64 {
        clips.reduce(Int64(0)) { $0 + $1.timelineDurationMs }
    }

    /// Calculates timeline start time for a clip at given index
    func timelineStartTime(forClipIndex index: Int) -> Int64 {
        guard index > 0 && index < clips.count else { return 0 }
        return clips[0..<index].reduce(Int64(0)) { $0 + $1.timelineDurationMs }
    }

    /// Finds the clip active at a given timeline millisecond
    func clipIndex(at timelineMs: Int64) -> Int? {
        guard !clips.isEmpty else { return nil }
        var accumulated: Int64 = 0
        for (idx, clip) in clips.enumerated() {
            let nextAccum = accumulated + clip.timelineDurationMs
            if timelineMs >= accumulated && timelineMs < nextAccum {
                return idx
            }
            accumulated = nextAccum
        }
        return clips.count - 1
    }

    /// Splits a clip at given timeline position, maintaining keyframe animation continuity across both segments
    mutating func splitClip(at timelineMs: Int64) -> Bool {
        guard let index = clipIndex(at: timelineMs) else { return false }
        let clip = clips[index]
        let clipStartTimelineMs = timelineStartTime(forClipIndex: index)
        let offsetMs = timelineMs - clipStartTimelineMs

        // Guard against splitting too close to edges (minimum 100ms)
        guard offsetMs >= 100 && (clip.timelineDurationMs - offsetMs) >= 100 else {
            return false
        }

        let splitSourceMs = clip.mapTimelineOffsetToSourceMs(offsetMs)

        // Split keyframes with boundary continuity
        var firstKeyframes: [ClipKeyframe] = []
        var secondKeyframes: [ClipKeyframe] = []

        for prop in KeyframeProperty.allCases {
            let propKfs = clip.keyframes(for: prop)
            if !propKfs.isEmpty {
                let midVal = clip.evaluate(property: prop, at: offsetMs, defaultValue: prop.defaultVal)
                // First clip keyframes
                for kf in propKfs where kf.timeMs < offsetMs {
                    firstKeyframes.append(kf)
                }
                firstKeyframes.append(ClipKeyframe(timeMs: offsetMs, property: prop, value: midVal, easing: .easeInOut))

                // Second clip keyframes
                secondKeyframes.append(ClipKeyframe(timeMs: 0, property: prop, value: midVal, easing: .easeInOut))
                for kf in propKfs where kf.timeMs > offsetMs {
                    var shifted = kf
                    shifted.id = UUID()
                    shifted.timeMs = kf.timeMs - offsetMs
                    secondKeyframes.append(shifted)
                }
            }
        }

        var firstClip = clip
        firstClip.id = UUID()
        firstClip.sourceOutPointMs = splitSourceMs
        firstClip.keyframes = firstKeyframes

        var secondClip = clip
        secondClip.id = UUID()
        secondClip.sourceInPointMs = splitSourceMs
        secondClip.keyframes = secondKeyframes

        clips.remove(at: index)
        clips.insert(secondClip, at: index)
        clips.insert(firstClip, at: index)
        updatedAt = Date()
        return true
    }
}
