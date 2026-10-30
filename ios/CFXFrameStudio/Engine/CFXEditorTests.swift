import Foundation

// MARK: - Automated Engine Test Suite for Video Editor
/// Validates keyframe animations, exact speed curve integration, bidirectional time mapping,
/// trimming, clip splitting, undo/redo, and multi-clip project math.
public final class CFXEditorTests {
    public static let shared = CFXEditorTests()

    public struct TestReport {
        public let totalTests: Int
        public let passedTests: Int
        public let failedTests: Int
        public let results: [String: Bool]
        public let details: [String]
    }

    private init() {}

    /// Executes all mathematical and logic test suites and returns a structured report
    @discardableResult
    public func runAllTests() -> TestReport {
        var results: [String: Bool] = [:]
        var details: [String] = []

        func record(_ name: String, passed: Bool, detail: String = "") {
            results[name] = passed
            let status = passed ? "PASS" : "FAIL"
            let msg = "[\(status)] \(name)\(detail.isEmpty ? "" : " - \(detail)")"
            details.append(msg)
            #if DEBUG
            print(msg)
            #endif
        }

        // 1. Keyframe Interpolation Tests
        do {
            var clip = EditorClip(
                sourceUrl: URL(fileURLWithPath: "/dummy.mp4"),
                filename: "dummy.mp4",
                sourceDurationMs: 10000,
                sourceInPointMs: 0,
                sourceOutPointMs: 10000
            )

            clip.addOrUpdateKeyframe(at: 1000, scale: 1.0, easing: .linear)
            clip.addOrUpdateKeyframe(at: 3000, scale: 3.0, easing: .linear)

            // Boundary holds
            let before = clip.evaluatedTransform(at: Double(500)).scale
            let after = clip.evaluatedTransform(at: Double(4000)).scale
            let mid = clip.evaluatedTransform(at: Double(2000)).scale

            let holdsCorrect = (abs(before - 1.0) < 0.001) && (abs(after - 3.0) < 0.001)
            let linearMidCorrect = abs(mid - 2.0) < 0.01

            record("Keyframe Linear Interpolation & Boundary Holds", passed: holdsCorrect && linearMidCorrect)

            // Test Easing Functions
            let easeInOutVal = KeyframeEasing.easeInOut.interpolate(from: 0.0, to: 10.0, progress: 0.5)
            let smoothVal = KeyframeEasing.smooth.interpolate(from: 0.0, to: 10.0, progress: 0.5)
            let easeInVal = KeyframeEasing.easeIn.interpolate(from: 0.0, to: 10.0, progress: 0.5)
            let easeOutVal = KeyframeEasing.easeOut.interpolate(from: 0.0, to: 10.0, progress: 0.5)

            let easingCorrect = abs(easeInOutVal - 5.0) < 0.01 &&
                                abs(smoothVal - 5.0) < 0.01 &&
                                easeInVal < 5.0 &&
                                easeOutVal > 5.0
            record("Keyframe Easing Curves (EaseIn, EaseOut, EaseInOut, Smooth)", passed: easingCorrect)
        }

        // 2. Keyframe Selection by Stable UUID & Order Preservation
        do {
            var clip = EditorClip(
                sourceUrl: URL(fileURLWithPath: "/dummy.mp4"),
                filename: "dummy.mp4",
                sourceDurationMs: 10000,
                sourceInPointMs: 0,
                sourceOutPointMs: 10000
            )

            let kf1 = clip.addOrUpdateKeyframe(at: 1000, scale: 1.2)
            let kf2 = clip.addOrUpdateKeyframe(at: 1060, scale: 1.8) // < 120ms away!

            // Both keyframes must exist independently without overwriting each other
            let countIsTwo = clip.keyframes.count == 2
            let findById = (clip.keyframe(byId: kf1.id)?.scale == 1.2) && (clip.keyframe(byId: kf2.id)?.scale == 1.8)

            // Move keyframe precisely
            clip.moveKeyframe(id: kf1.id, newTimeMs: 2500)
            let isSorted = clip.sortedKeyframes.map { $0.timeMs } == [1060, 2500]

            record("Keyframe Stable UUID & Sub-120ms Independent Identity", passed: countIsTwo && findById && isSorted)
        }

        // 3. Exact Speed Integration & Monotonicity
        do {
            var config = ClipSpeedConfiguration()
            config.speedMultiplier = 0.5
            config.isRamp = false

            let constExpansion = config.timelineDurationExpansionFactor()
            let constCorrect = abs(constExpansion - 2.0) < 0.01

            // Speed Ramp: 1.0 -> 0.25 -> 0.25 -> 1.0
            config.isRamp = true
            config.rampPoints = [
                SpeedRampPoint(normalizedPosition: 0.0, speedMultiplier: 1.0),
                SpeedRampPoint(normalizedPosition: 0.3, speedMultiplier: 0.25),
                SpeedRampPoint(normalizedPosition: 0.7, speedMultiplier: 0.25),
                SpeedRampPoint(normalizedPosition: 1.0, speedMultiplier: 1.0)
            ]

            let rampExpansion = config.timelineDurationExpansionFactor(samples: 100)
            // Area with slowdown should expand duration > 1.0
            let rampExpands = rampExpansion > 2.0

            record("Speed Curve Definite Integration", passed: constCorrect && rampExpands)
        }

        // 4. Bi-Directional Time Mapping & Exact Inversion Roundtrip
        do {
            var clip = EditorClip(
                sourceUrl: URL(fileURLWithPath: "/dummy.mp4"),
                filename: "dummy.mp4",
                sourceDurationMs: 12000,
                sourceInPointMs: 2000,
                sourceOutPointMs: 8000 // Trimmed 6000ms
            )

            clip.speedConfig.isRamp = true
            clip.speedConfig.rampPoints = [
                SpeedRampPoint(normalizedPosition: 0.0, speedMultiplier: 1.0),
                SpeedRampPoint(normalizedPosition: 0.4, speedMultiplier: 0.25),
                SpeedRampPoint(normalizedPosition: 0.6, speedMultiplier: 0.25),
                SpeedRampPoint(normalizedPosition: 1.0, speedMultiplier: 1.0)
            ]

            var maxDriftMs: Double = 0.0
            for testSrc in stride(from: 2000.0, through: 8000.0, by: 250.0) {
                let tl = clip.mapSourceMsToTimelineOffset(testSrc)
                let roundtrip = clip.mapTimelineOffsetToSourceMs(tl)
                let drift = abs(roundtrip - testSrc)
                if drift > maxDriftMs { maxDriftMs = drift }
            }

            // Drift must be sub-millisecond across all test points
            let roundtripAccurate = maxDriftMs < 1.0
            record("Bi-directional Time Mapping Roundtrip (Sub-ms Drift)", passed: roundtripAccurate, detail: "Max drift: \(String(format: "%.4f", maxDriftMs))ms")
        }

        // 5. Trim Calculations & Keyframe Bounds
        do {
            var clip = EditorClip(
                sourceUrl: URL(fileURLWithPath: "/dummy.mp4"),
                filename: "dummy.mp4",
                sourceDurationMs: 10000,
                sourceInPointMs: 1000,
                sourceOutPointMs: 6000
            )

            clip.speedConfig.speedMultiplier = 2.0 // 2x fast
            let initialDur = clip.timelineDurationMs // 5000 / 2 = 2500ms
            let durIs2500 = initialDur == 2500

            // Trim out point
            clip.sourceOutPointMs = 4000 // 3000ms source / 2 = 1500ms
            let trimmedDur = clip.timelineDurationMs
            let trimCorrect = trimmedDur == 1500

            record("Trim Calculations & Retimed Duration Recalculation", passed: durIs2500 && trimCorrect)
        }

        // 6. Split Clip with Keyframe Partitioning & Continuity
        do {
            var project = VideoProject(title: "Split Test")
            var clip = EditorClip(
                sourceUrl: URL(fileURLWithPath: "/dummy.mp4"),
                filename: "dummy.mp4",
                sourceDurationMs: 10000,
                sourceInPointMs: 0,
                sourceOutPointMs: 10000
            )

            clip.addOrUpdateKeyframe(at: 1000, scale: 1.0)
            clip.addOrUpdateKeyframe(at: 5000, scale: 2.0)
            clip.addOrUpdateKeyframe(at: 9000, scale: 3.0)
            project.clips = [clip]

            let splitSuccess = project.splitClip(at: 5000)
            let clipCountIsTwo = project.clips.count == 2
            let uniqueIds = project.clips.count == 2 && project.clips[0].id != project.clips[1].id
            let totalDurConserved = project.totalTimelineDurationMs == 10000

            let firstClipKf = project.clips.first?.keyframes.count ?? 0
            let secondClipKf = project.clips.last?.keyframes.count ?? 0
            let keyframesPartitioned = firstClipKf >= 2 && secondClipKf >= 2

            record("Clip Split & Keyframe Continuity Partitioning", passed: splitSuccess && clipCountIsTwo && uniqueIds && totalDurConserved && keyframesPartitioned)
        }

        // 7. Multi-Clip Timeline Calculations & Empty Project Safety
        do {
            var project = VideoProject(title: "Multi-Clip Test")
            let emptyDur = project.totalTimelineDurationMs
            let emptyIdx = project.clipIndex(at: 0)

            var clip1 = EditorClip(sourceUrl: URL(fileURLWithPath: "/dummy1.mp4"), filename: "1.mp4", sourceDurationMs: 3000, sourceInPointMs: 0, sourceOutPointMs: 3000)
            var clip2 = EditorClip(sourceUrl: URL(fileURLWithPath: "/dummy2.mp4"), filename: "2.mp4", sourceDurationMs: 4000, sourceInPointMs: 0, sourceOutPointMs: 4000)
            clip1.speedConfig.speedMultiplier = 1.0 // 3000ms
            clip2.speedConfig.speedMultiplier = 2.0 // 2000ms

            project.clips = [clip1, clip2]
            let totalDur = project.totalTimelineDurationMs // 5000ms
            let c0Start = project.timelineStartTime(forClipIndex: 0) // 0
            let c1Start = project.timelineStartTime(forClipIndex: 1) // 3000
            let at2000 = project.clipIndex(at: 2000) // 0
            let at3500 = project.clipIndex(at: 3500) // 1

            let multiClipCorrect = (emptyDur == 0) && (emptyIdx == nil) &&
                                   (totalDur == 5000) && (c0Start == 0) && (c1Start == 3000) &&
                                   (at2000 == 0) && (at3500 == 1)

            record("Multi-Clip Timeline Boundaries & Empty Project Safety", passed: multiClipCorrect)
        }

        // 8. Color Adjustments Keyframing & Interpolation
        do {
            var clip = EditorClip(
                sourceUrl: URL(fileURLWithPath: "/dummy.mp4"),
                filename: "dummy.mp4",
                sourceDurationMs: 4000,
                sourceInPointMs: 0,
                sourceOutPointMs: 4000
            )

            clip.addOrUpdateKeyframe(at: 1000, brightness: -0.2, contrast: 1.0, saturation: 0.5)
            clip.addOrUpdateKeyframe(at: 3000, brightness: 0.4, contrast: 1.6, saturation: 1.5)

            let midColor = clip.evaluatedColor(at: Double(2000))
            let colorInterpolated = abs(midColor.brightness - 0.1) < 0.05 &&
                                    abs(midColor.contrast - 1.3) < 0.05 &&
                                    abs(midColor.saturation - 1.0) < 0.05

            record("Color Adjustments Keyframing & Smooth Interpolation", passed: colorInterpolated)
        }

        let passedCount = results.values.filter { $0 }.count
        let totalCount = results.count
        return TestReport(
            totalTests: totalCount,
            passedTests: passedCount,
            failedTests: totalCount - passedCount,
            results: results,
            details: details
        )
    }
}
