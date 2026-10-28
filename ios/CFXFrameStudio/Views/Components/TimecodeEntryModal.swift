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
    let onApply: (Int64) -> Void
    let onDismiss: () -> Void

    @State private var timecodeText: String = ""
    @State private var errorMessage: String? = nil

    init(
        target: TimecodeTarget,
        initialMs: Int64,
        durationMs: Int64,
        onApply: @escaping (Int64) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.target = target
        self.initialMs = initialMs
        self.durationMs = durationMs
        self.onApply = onApply
        self.onDismiss = onDismiss
        _timecodeText = State(initialValue: formatMsToTimecode(initialMs))
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

                Text("Enter timecode (HH:MM:SS.mmm, MM:SS.mmm, or seconds)")
                    .font(.system(size: 12))
                    .foregroundColor(.textMuted)

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
                        if let parsedMs = parseTimecodeToMs(timecodeText) {
                            let clamped = max(0, min(durationMs, parsedMs))
                            onApply(clamped)
                            onDismiss()
                        } else {
                            errorMessage = "Invalid timecode format (e.g. 01:23.450 or 83.45)"
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

func parseTimecodeToMs(_ input: String) -> Int64? {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let sec = Double(raw) {
        return Int64(sec * 1000.0)
    }

    let parts = raw.split(separator: ":").map { String($0) }
    if parts.count == 3 {
        // HH:MM:SS[.mmm]
        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return Int64((h * 3600.0 + m * 60.0 + s) * 1000.0)
    } else if parts.count == 2 {
        // MM:SS[.mmm]
        guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return Int64((m * 60.0 + s) * 1000.0)
    }
    return nil
}
