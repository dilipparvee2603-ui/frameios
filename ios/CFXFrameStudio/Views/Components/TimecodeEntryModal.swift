import SwiftUI

enum TimecodeTarget: String, Identifiable {
    case inPoint = "Set In-Point Timecode"
    case outPoint = "Set Out-Point Timecode"
    case playhead = "Jump to Timecode"

    var id: String { rawValue }
}

struct TimecodeEntryModal: View {
    let target: TimecodeTarget
    let initialMs: Int64
    let durationMs: Int64
    let fps: Double
    let onApply: (Int64) -> Void
    let onDismiss: () -> Void

    @State private var timecodeText: String = ""
    @State private var errorMessage: String? = nil
    @State private var clipboardPreview: String? = nil

    init(
        target: TimecodeTarget,
        initialMs: Int64,
        durationMs: Int64,
        fps: Double = 30.0,
        onApply: @escaping (Int64) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.target = target
        self.initialMs = initialMs
        self.durationMs = durationMs
        self.fps = fps
        self.onApply = onApply
        self.onDismiss = onDismiss
        _timecodeText = State(initialValue: formatToSMPTETimecode(seconds: Double(initialMs) / 1000.0, fps: fps))
    }

    private func checkClipboard() {
        if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
            if parseTimecodeToMs(clip, fps: fps) != nil {
                clipboardPreview = clip
            }
        }
    }

    private func pasteFromClipboard() {
        if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
            timecodeText = clip
            errorMessage = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 14) {
                Text(target.rawValue)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text("Enter or paste timecode (HH:MM:SS.mmm, MM:SS.mmm, or seconds)")
                    .font(.system(size: 12))
                    .foregroundColor(.textMuted)

                HStack(spacing: 8) {
                    TextField("00:00:00.000", text: $timecodeText)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .padding(12)
                        .background(Color.elevatedSurface)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(errorMessage != nil ? Color.brandAccent : Color.borderHairline, lineWidth: 1)
                        )
                        .foregroundColor(.textPrimary)
                        .keyboardType(.numbersAndPunctuation)

                    Button(action: pasteFromClipboard) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard.fill")
                            Text("Paste")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(Color.skyAccent.opacity(0.18))
                        .foregroundColor(.skyAccent)
                        .cornerRadius(10)
                    }
                }

                if let clip = clipboardPreview, clip != timecodeText {
                    Button(action: {
                        timecodeText = clip
                        errorMessage = nil
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.amberAccent)
                                .font(.system(size: 11))
                            Text("Clipboard: \"\(clip)\" • Tap to use")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.textPrimary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.amberAccent.opacity(0.12))
                        .cornerRadius(8)
                    }
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.brandAccent)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        onDismiss()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Button("Apply") {
                        if let parsedMs = parseTimecodeToMs(timecodeText, fps: fps) {
                            let clamped = max(0, min(durationMs, parsedMs))
                            onApply(clamped)
                            onDismiss()
                        } else {
                            errorMessage = "Invalid timecode format (e.g. 01:23:15 or 83.45)"
                        }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.brandAccent)
                    .cornerRadius(10)
                }
            }
            .padding(20)
            .background(Color.surfaceCard)
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.borderHairlineBright, lineWidth: 1)
            )
            .padding(24)
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
        .onAppear {
            checkClipboard()
        }
    }
}

func formatMsToTimecode(_ ms: Int64) -> String {
    let totalSec = Double(ms) / 1000.0
    let hours = Int(totalSec) / 3600
    let minutes = (Int(totalSec) % 3600) / 60
    let seconds = Int(totalSec) % 60
    let millis = Int(ms % 1000)
    return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
}

func formatToSMPTETimecode(seconds: Double, fps: Double) -> String {
    let safeFps = max(1.0, fps)
    guard seconds.isFinite && !seconds.isNaN && seconds >= 0 else {
        return "00:00:00:00"
    }
    let totalFrames = Int64(round(seconds * safeFps))
    let fpsInt = Int64(round(safeFps))
    let frames = totalFrames % max(1, fpsInt)
    let totalSecInt = Int64(seconds)
    let hours = totalSecInt / 3600
    let minutes = (totalSecInt % 3600) / 60
    let secondsInt = totalSecInt % 60
    return String(format: "%02d:%02d:%02d:%02d", hours, minutes, secondsInt, frames)
}

func formatMsToSMPTETimecode(_ ms: Int64, fps: Double) -> String {
    let sec = Double(ms) / 1000.0
    return formatToSMPTETimecode(seconds: sec, fps: fps)
}

func parseTimecodeToMs(_ input: String, fps: Double = 30.0) -> Int64? {
    var clean = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ";", with: ":")
    if clean.isEmpty { return nil }

    // If string contains non-digit/punctuation text (e.g. "Timecode: 00:01:23.450"), extract timecode pattern
    if let match = clean.range(of: #"\b\d{1,2}:\d{2}(:\d{2})?([.:]\d+)?\b"#, options: .regularExpression) {
        clean = String(clean[match])
    }

    // Plain seconds with decimal (e.g. "83.5")
    if !clean.contains(":") {
        let numericOnly = clean.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.").inverted)
        if let sec = Double(numericOnly) {
            return Int64(round(sec * 1000.0))
        }
    }

    let parts = clean.split(separator: ":").map { String($0) }
    let safeFps = max(1.0, fps)
    if parts.count == 4 {
        // SMPTE standard: HH:MM:SS:FF
        guard let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]),
              let f = Double(parts[3]) else { return nil }
        let totalSec = h * 3600.0 + m * 60.0 + s + (f / safeFps)
        return Int64(round(totalSec * 1000.0))
    } else if parts.count == 3 {
        // HH:MM:SS[.mmm]
        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return Int64(round((h * 3600.0 + m * 60.0 + s) * 1000.0))
    } else if parts.count == 2 {
        // MM:SS[.mmm]
        guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return Int64(round((m * 60.0 + s) * 1000.0))
    }
    return nil
}
