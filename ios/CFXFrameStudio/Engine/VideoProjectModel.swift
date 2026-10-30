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
    var opacity: Double = 1.0
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
            // Continuous cubic Hermite Ease In-Out (Smoothstep: 3t^2 - 2t^3):
            // Zero velocity at endpoints, continuous acceleration with zero midpoint jump
            easedT = clampedT * clampedT * (3.0 - 2.0 * clampedT)
        case .smooth:
            // Continuous cosine ease curve: (1 - cos(pi * t)) / 2 (Alight Motion / After Effects curve)
            easedT = (1.0 - cos(clampedT * .pi)) / 2.0
        }
        return v0 + (v1 - v0) * easedT
    }
}

struct ClipKeyframe: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var timeMs: Int64              // Clip-local presentation timestamp in ms (0 ... clip.timelineDurationMs)
    var positionX: Double = 0.0    // Canvas offset X in pt
    var positionY: Double = 0.0    // Canvas offset Y in pt
    var scale: Double = 1.0        // Zoom scale (1.0 = normal)
    var rotationDegrees: Double = 0.0 // Rotation angle in degrees
    var opacity: Double = 1.0      // Opacity (0.0 ... 1.0)
    var brightness: Double = 0.0   // Brightness adjustment (-1.0 to 1.0)
    var contrast: Double = 1.0     // Contrast adjustment (0.0 to 2.0)
    var saturation: Double = 1.0   // Saturation adjustment (0.0 to 2.0)
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

    init(id: UUID = UUID(), normalizedPosition: Double, speedMultiplier: Double) {
        self.id = id
        self.normalizedPosition = normalizedPosition
        self.speedMultiplier = speedMultiplier
    }
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

    /// Total expansion factor: integral of 1 / speed(u) du from 0 to 1
    func timelineDurationExpansionFactor(samples: Int = 100) -> Double {
        guard isRamp, rampPoints.count >= 2 else {
            return 1.0 / max(0.05, speedMultiplier)
        }
        var sum = 0.0
        let step = 1.0 / Double(samples)
        for i in 0..<samples {
            let u = (Double(i) + 0.5) * step
            let s = evaluateSpeed(at: u)
            sum += (1.0 / max(0.05, s))
        }
        return sum * step
    }

    /// Evaluates timeline progress (0.0 ... 1.0) given source media progress (0.0 ... 1.0) via definite integration
    func mapSourceProgressToTimelineProgress(_ sourceProgress: Double, samples: Int = 100) -> Double {
        let clampedSource = max(0.0, min(1.0, sourceProgress))
        guard isRamp, rampPoints.count >= 2 else {
            return clampedSource
        }
        guard clampedSource > 0.0 else { return 0.0 }
        guard clampedSource < 1.0 else { return 1.0 }

        let totalFactor = timelineDurationExpansionFactor(samples: samples)
        guard totalFactor > 0.0001 else { return clampedSource }

        let n = max(10, Int(round(Double(samples) * clampedSource)))
        let step = clampedSource / Double(n)
        var partialSum = 0.0
        for i in 0..<n {
            let u = (Double(i) + 0.5) * step
            let s = evaluateSpeed(at: u)
            partialSum += (1.0 / max(0.05, s))
        }
        let partialIntegral = partialSum * step
        return min(1.0, max(0.0, partialIntegral / totalFactor))
    }

    /// Inverts timeline progress (0.0 ... 1.0) back to source media progress (0.0 ... 1.0) via monotonic binary search
    func mapTimelineProgressToSourceProgress(_ timelineProgress: Double, samples: Int = 100) -> Double {
        let clampedTimeline = max(0.0, min(1.0, timelineProgress))
        guard isRamp, rampPoints.count >= 2 else {
            return clampedTimeline
        }
        guard clampedTimeline > 0.0 else { return 0.0 }
        guard clampedTimeline < 1.0 else { return 1.0 }

        var low = 0.0
        var high = 1.0
        for _ in 0..<18 {
            let mid = (low + high) * 0.5
            let midTl = mapSourceProgressToTimelineProgress(mid, samples: samples)
            if midTl < clampedTimeline {
                low = mid
            } else {
                high = mid
            }
        }
        return (low + high) * 0.5
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

    init(
        id: UUID = UUID(),
        sourceUrl: URL,
        filename: String,
        sourceDurationMs: Int64,
        sourceInPointMs: Int64,
        sourceOutPointMs: Int64,
        speedConfig: ClipSpeedConfiguration = ClipSpeedConfiguration(),
        transform: TransformGeometry = TransformGeometry(),
        color: ColorAdjustments = ColorAdjustments(),
        keyframes: [ClipKeyframe] = [],
        volume: Double = 1.0,
        isMuted: Bool = false,
        transitionOut: TransitionType = .cut,
        transitionDurationMs: Int64 = 500
    ) {
        self.id = id
        self.sourceUrl = sourceUrl
        self.filename = filename
        self.sourceDurationMs = sourceDurationMs
        self.sourceInPointMs = sourceInPointMs
        self.sourceOutPointMs = sourceOutPointMs
        self.speedConfig = speedConfig
        self.transform = transform
        self.color = color
        self.keyframes = keyframes
        self.volume = volume
        self.isMuted = isMuted
        self.transitionOut = transitionOut
        self.transitionDurationMs = transitionDurationMs
    }

    // MARK: - InShot-Style Keyframe Animation System
    func hasKeyframes() -> Bool {
        !keyframes.isEmpty
    }

    var sortedKeyframes: [ClipKeyframe] {
        keyframes.sorted { $0.timeMs < $1.timeMs }
    }

    func keyframe(byId id: UUID) -> ClipKeyframe? {
        keyframes.first { $0.id == id }
    }

    func keyframeIndex(byId id: UUID) -> Int? {
        keyframes.firstIndex { $0.id == id }
    }

    func keyframe(near timeMs: Int64, toleranceMs: Int64 = 40) -> ClipKeyframe? {
        keyframes.filter { abs($0.timeMs - timeMs) <= toleranceMs }
            .min(by: { abs($0.timeMs - timeMs) < abs($1.timeMs - timeMs) })
    }

    func keyframeIndex(near timeMs: Int64, toleranceMs: Int64 = 40) -> Int? {
        guard let kf = keyframe(near: timeMs, toleranceMs: toleranceMs) else { return nil }
        return keyframeIndex(byId: kf.id)
    }

    mutating func moveKeyframe(id: UUID, newTimeMs: Int64) {
        guard let idx = keyframeIndex(byId: id) else { return }
        let clamped = max(0, min(timelineDurationMs, newTimeMs))
        var finalTime = clamped
        if keyframes.contains(where: { $0.id != id && $0.timeMs == finalTime }) {
            finalTime = min(timelineDurationMs, finalTime + 1)
        }
        keyframes[idx].timeMs = finalTime
        keyframes.sort { $0.timeMs < $1.timeMs }
    }

    @discardableResult
    mutating func addOrUpdateKeyframe(
        id: UUID? = nil,
        at timeMs: Int64,
        positionX: Double? = nil,
        positionY: Double? = nil,
        scale: Double? = nil,
        rotationDegrees: Double? = nil,
        opacity: Double? = nil,
        brightness: Double? = nil,
        contrast: Double? = nil,
        saturation: Double? = nil,
        easing: KeyframeEasing? = nil
    ) -> ClipKeyframe {
        let clampedTime = max(0, min(timelineDurationMs, timeMs))
        let curTransform = evaluatedTransform(at: Double(clampedTime))
        let curColor = evaluatedColor(at: Double(clampedTime))

        let targetIdx: Int?
        if let targetId = id, let idx = keyframeIndex(byId: targetId) {
            targetIdx = idx
        } else if let exactIdx = keyframes.firstIndex(where: { abs($0.timeMs - clampedTime) <= 5 }) {
            targetIdx = exactIdx
        } else {
            targetIdx = nil
        }

        if let idx = targetIdx {
            if let px = positionX { keyframes[idx].positionX = px }
            if let py = positionY { keyframes[idx].positionY = py }
            if let sc = scale { keyframes[idx].scale = max(0.1, sc) }
            if let rot = rotationDegrees { keyframes[idx].rotationDegrees = rot }
            if let op = opacity { keyframes[idx].opacity = max(0.0, min(1.0, op)) }
            if let br = brightness { keyframes[idx].brightness = br }
            if let ct = contrast { keyframes[idx].contrast = ct }
            if let st = saturation { keyframes[idx].saturation = st }
            if let es = easing { keyframes[idx].easing = es }
            return keyframes[idx]
        } else {
            let newKf = ClipKeyframe(
                id: id ?? UUID(),
                timeMs: clampedTime,
                positionX: positionX ?? curTransform.offsetX,
                positionY: positionY ?? curTransform.offsetY,
                scale: scale ?? curTransform.scale,
                rotationDegrees: rotationDegrees ?? curTransform.rotationDegrees,
                opacity: opacity ?? curTransform.opacity,
                brightness: brightness ?? curColor.brightness,
                contrast: contrast ?? curColor.contrast,
                saturation: saturation ?? curColor.saturation,
                easing: easing ?? .easeInOut
            )
            keyframes.append(newKf)
            keyframes.sort { $0.timeMs < $1.timeMs }
            return newKf
        }
    }

    mutating func removeKeyframe(byId id: UUID) {
        keyframes.removeAll { $0.id == id }
    }

    mutating func removeKeyframe(near timeMs: Int64, toleranceMs: Int64 = 40) {
        if let nearest = keyframes.min(by: { abs($0.timeMs - timeMs) < abs($1.timeMs - timeMs) }),
           abs(nearest.timeMs - timeMs) <= toleranceMs {
            keyframes.removeAll { $0.id == nearest.id }
        }
    }

    func previousKeyframeTime(from timeMs: Int64) -> Int64? {
        sortedKeyframes.filter { $0.timeMs < timeMs - 5 }.last?.timeMs
    }

    func nextKeyframeTime(from timeMs: Int64) -> Int64? {
        sortedKeyframes.filter { $0.timeMs > timeMs + 5 }.first?.timeMs
    }

    func allKeyframeTimes() -> [Int64] {
        sortedKeyframes.map { $0.timeMs }
    }

    /// Evaluates complete transform continuously at sub-millisecond clip-local presentation timestamp in ms
    func evaluatedTransform(at timeMs: Double) -> (scale: Double, offsetX: Double, offsetY: Double, rotationDegrees: Double, opacity: Double) {
        let sorted = sortedKeyframes
        guard !sorted.isEmpty else {
            return (
                max(0.1, transform.scale),
                transform.offsetX,
                transform.offsetY,
                Double(transform.rotation.rawValue),
                max(0.0, min(1.0, transform.opacity))
            )
        }

        let maxDuration = Double(timelineDurationMs)
        let clampedTime = max(0.0, min(maxDuration, timeMs))

        // Before first keyframe: hold first keyframe state
        if clampedTime <= Double(sorted.first!.timeMs) {
            let k0 = sorted.first!
            return (max(0.1, k0.scale), k0.positionX, k0.positionY, k0.rotationDegrees, max(0.0, min(1.0, k0.opacity)))
        }

        // After last keyframe: hold last keyframe state
        if clampedTime >= Double(sorted.last!.timeMs) {
            let kLast = sorted.last!
            return (max(0.1, kLast.scale), kLast.positionX, kLast.positionY, kLast.rotationDegrees, max(0.0, min(1.0, kLast.opacity)))
        }

        // Between two keyframes: continuous smooth mathematical interpolation
        for i in 0..<(sorted.count - 1) {
            let k0 = sorted[i]
            let k1 = sorted[i + 1]
            let t0 = Double(k0.timeMs)
            let t1 = Double(k1.timeMs)
            if clampedTime >= t0 && clampedTime <= t1 {
                let span = t1 - t0
                guard span > 0.001 else {
                    return (max(0.1, k0.scale), k0.positionX, k0.positionY, k0.rotationDegrees, max(0.0, min(1.0, k0.opacity)))
                }
                let progress = max(0.0, min(1.0, (clampedTime - t0) / span))
                let s = k0.easing.interpolate(from: k0.scale, to: k1.scale, progress: progress)
                let x = k0.easing.interpolate(from: k0.positionX, to: k1.positionX, progress: progress)
                let y = k0.easing.interpolate(from: k0.positionY, to: k1.positionY, progress: progress)
                let r = k0.easing.interpolate(from: k0.rotationDegrees, to: k1.rotationDegrees, progress: progress)
                let o = k0.easing.interpolate(from: k0.opacity, to: k1.opacity, progress: progress)
                return (max(0.1, s), x, y, r, max(0.0, min(1.0, o)))
            }
        }

        return (transform.scale, transform.offsetX, transform.offsetY, Double(transform.rotation.rawValue), max(0.0, min(1.0, transform.opacity)))
    }

    /// Convenience overload for integer millisecond timestamp
    func evaluatedTransform(at timeMs: Int64) -> (scale: Double, offsetX: Double, offsetY: Double, rotationDegrees: Double, opacity: Double) {
        evaluatedTransform(at: Double(timeMs))
    }

    /// Evaluates color adjustments at a clip-local presentation time (ms)
    func evaluatedColor(at timeMs: Double) -> ColorAdjustments {
        let sorted = sortedKeyframes
        guard !sorted.isEmpty else {
            return color
        }
        let maxDuration = Double(timelineDurationMs)
        let clampedTime = max(0.0, min(maxDuration, timeMs))

        let hasCustomColor = sorted.contains {
            $0.brightness != 0.0 || $0.contrast != 1.0 || $0.saturation != 1.0
        }
        guard hasCustomColor else { return color }

        if clampedTime <= Double(sorted.first!.timeMs) {
            let k0 = sorted.first!
            var c = color
            c.brightness = k0.brightness
            c.contrast = k0.contrast
            c.saturation = k0.saturation
            return c
        }

        if clampedTime >= Double(sorted.last!.timeMs) {
            let kLast = sorted.last!
            var c = color
            c.brightness = kLast.brightness
            c.contrast = kLast.contrast
            c.saturation = kLast.saturation
            return c
        }

        for i in 0..<(sorted.count - 1) {
            let k0 = sorted[i]
            let k1 = sorted[i + 1]
            let t0 = Double(k0.timeMs)
            let t1 = Double(k1.timeMs)
            if clampedTime >= t0 && clampedTime <= t1 {
                let span = t1 - t0
                guard span > 0.001 else {
                    var c = color
                    c.brightness = k0.brightness
                    c.contrast = k0.contrast
                    c.saturation = k0.saturation
                    return c
                }
                let progress = max(0.0, min(1.0, (clampedTime - t0) / span))
                var c = color
                c.brightness = k0.easing.interpolate(from: k0.brightness, to: k1.brightness, progress: progress)
                c.contrast = k0.easing.interpolate(from: k0.contrast, to: k1.contrast, progress: progress)
                c.saturation = k0.easing.interpolate(from: k0.saturation, to: k1.saturation, progress: progress)
                return c
            }
        }
        return color
    }

    func evaluatedColor(at timeMs: Int64) -> ColorAdjustments {
        evaluatedColor(at: Double(timeMs))
    }

    // MARK: - Computed Durations
    /// Raw un-stretched source media trimmed duration in ms
    var sourceTrimmedDurationMs: Int64 {
        max(50, sourceOutPointMs - sourceInPointMs)
    }

    /// Effective timeline duration after speed retiming in ms
    var timelineDurationMs: Int64 {
        let factor = speedConfig.timelineDurationExpansionFactor()
        return max(50, Int64(round(Double(sourceTrimmedDurationMs) * factor)))
    }

    /// Maps a millisecond offset within this clip on the timeline to the corresponding source media timestamp (ms)
    func mapTimelineOffsetToSourceMs(_ offsetMs: Int64) -> Int64 {
        Int64(round(mapTimelineOffsetToSourceMs(Double(offsetMs))))
    }

    /// Double-precision continuous time mapping from timeline offset (ms) to source media timestamp (ms)
    func mapTimelineOffsetToSourceMs(_ offsetMs: Double) -> Double {
        let tlDur = Double(timelineDurationMs)
        guard tlDur > 0 else { return Double(sourceInPointMs) }
        let tlProgress = max(0.0, min(1.0, offsetMs / tlDur))
        let srcProgress = speedConfig.mapTimelineProgressToSourceProgress(tlProgress)
        let srcTrimmed = Double(sourceTrimmedDurationMs)
        let srcMs = Double(sourceInPointMs) + (srcProgress * srcTrimmed)
        return min(Double(sourceOutPointMs), max(Double(sourceInPointMs), srcMs))
    }

    /// Maps a source timestamp (ms) back to this clip's timeline offset (ms)
    func mapSourceMsToTimelineOffset(_ srcMs: Int64) -> Int64 {
        Int64(round(mapSourceMsToTimelineOffset(Double(srcMs))))
    }

    /// Double-precision continuous time mapping from source timestamp (ms) to timeline offset (ms)
    func mapSourceMsToTimelineOffset(_ srcMs: Double) -> Double {
        let srcTrimmed = Double(sourceTrimmedDurationMs)
        guard srcTrimmed > 0 else { return 0.0 }
        let clampedSrc = min(Double(sourceOutPointMs), max(Double(sourceInPointMs), srcMs))
        let srcProgress = (clampedSrc - Double(sourceInPointMs)) / srcTrimmed
        let tlProgress = speedConfig.mapSourceProgressToTimelineProgress(srcProgress)
        return tlProgress * Double(timelineDurationMs)
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

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        timelineStartMs: Int64 = 0,
        durationMs: Int64,
        volume: Double = 1.0,
        isMuted: Bool = false,
        fadeInMs: Int64 = 0,
        fadeOutMs: Int64 = 0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.timelineStartMs = timelineStartMs
        self.durationMs = durationMs
        self.volume = volume
        self.isMuted = isMuted
        self.fadeInMs = fadeInMs
        self.fadeOutMs = fadeOutMs
    }
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

    init(
        id: UUID = UUID(),
        text: String = "Title Text",
        fontName: String = "HelveticaNeue-Bold",
        fontSize: CGFloat = 36.0,
        textColorHex: String = "FFFFFF",
        backgroundColorHex: String? = nil,
        alignment: String = "center",
        timelineStartMs: Int64 = 0,
        timelineEndMs: Int64 = 3000,
        posX: Double = 0.5,
        posY: Double = 0.8,
        scale: Double = 1.0
    ) {
        self.id = id
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.textColorHex = textColorHex
        self.backgroundColorHex = backgroundColorHex
        self.alignment = alignment
        self.timelineStartMs = timelineStartMs
        self.timelineEndMs = timelineEndMs
        self.posX = posX
        self.posY = posY
        self.scale = scale
    }
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

        if !clip.keyframes.isEmpty {
            let midTransform = clip.evaluatedTransform(at: Double(offsetMs))
            let midColor = clip.evaluatedColor(at: Double(offsetMs))

            // First clip keyframes
            for kf in clip.sortedKeyframes where kf.timeMs < offsetMs {
                var copy = kf
                copy.id = UUID()
                firstKeyframes.append(copy)
            }
            // Boundary keyframe at end of clip 1
            firstKeyframes.append(ClipKeyframe(
                id: UUID(),
                timeMs: offsetMs,
                positionX: midTransform.offsetX,
                positionY: midTransform.offsetY,
                scale: midTransform.scale,
                rotationDegrees: midTransform.rotationDegrees,
                opacity: midTransform.opacity,
                brightness: midColor.brightness,
                contrast: midColor.contrast,
                saturation: midColor.saturation,
                easing: .easeInOut
            ))

            // Boundary keyframe at start of clip 2 (time 0)
            secondKeyframes.append(ClipKeyframe(
                id: UUID(),
                timeMs: 0,
                positionX: midTransform.offsetX,
                positionY: midTransform.offsetY,
                scale: midTransform.scale,
                rotationDegrees: midTransform.rotationDegrees,
                opacity: midTransform.opacity,
                brightness: midColor.brightness,
                contrast: midColor.contrast,
                saturation: midColor.saturation,
                easing: .easeInOut
            ))

            // Shifted keyframes for clip 2
            for kf in clip.sortedKeyframes where kf.timeMs > offsetMs {
                var shifted = kf
                shifted.id = UUID()
                shifted.timeMs = kf.timeMs - offsetMs
                secondKeyframes.append(shifted)
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
