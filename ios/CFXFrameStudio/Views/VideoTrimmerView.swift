import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct VideoTrimmerView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var playerModel = PlayerModel()

    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false
    @State private var videoUrl: URL? = nil
    @State private var videoInfo: VideoInfo? = nil

    @State private var inPointMs: Int64 = 0
    @State private var outPointMs: Int64 = 0

    @State private var selectedPrecisionMode: TrimPrecisionMode = .frameAccurate
    @State private var timelineZoom: Double = 1.0 // 1.0 (Overview), 5.0 (Fine), 20.0 (Micro)

    @State private var includeAudioInExport: Bool = true
    @State private var isExporting: Bool = false
    @State private var exportProgress: Float = 0.0

    @State private var isRemuxing: Bool = false
    @State private var remuxProgress: Double = 0.0
    @State private var remuxSpeedText: String = ""

    @State private var trimmedFileUrl: URL? = nil
    @State private var showShareSheet: Bool = false

    @State private var activeTimecodeTarget: TimecodeTarget? = nil
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Header Bar
                    HStack {
                        Button(action: {
                            playerModel.cleanup()
                            dismiss()
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.textPrimary)
                                .frame(width: 36, height: 36)
                                .background(Color.surfaceCard)
                                .clipShape(Circle())
                        }

                        Text("VIDEO TRIMMER STUDIO")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Spacer()

                        HStack(spacing: 8) {
                            PhotosPicker(selection: $selectedItem, matching: .videos) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.gradientStart)
                                    .frame(width: 36, height: 36)
                                    .background(Color.surfaceCard)
                                    .clipShape(Circle())
                            }

                            Button(action: { showFilePicker = true }) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.gradientStart)
                                    .frame(width: 36, height: 36)
                                    .background(Color.surfaceCard)
                                    .clipShape(Circle())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    if videoUrl == nil {
                        // Empty State: Dual Import Options
                        VStack(spacing: 14) {
                            // Import from Camera Roll
                            PhotosPicker(selection: $selectedItem, matching: .videos) {
                                GlassCard(cornerRadius: 18, padding: 22) {
                                    HStack(spacing: 16) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.brandAccent.opacity(0.15))
                                                .frame(width: 48, height: 48)
                                            Image(systemName: "photo.on.rectangle.angled")
                                                .font(.system(size: 22, weight: .bold))
                                                .foregroundColor(.gradientStart)
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Import from Camera Roll")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.textPrimary)
                                            Text("Trim videos from your Photos library")
                                                .font(.system(size: 12))
                                                .foregroundColor(.textMuted)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.textTertiary)
                                    }
                                }
                            }

                            // Import from Files App
                            Button(action: { showFilePicker = true }) {
                                GlassCard(cornerRadius: 18, padding: 22) {
                                    HStack(spacing: 16) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.emeraldAccent.opacity(0.15))
                                                .frame(width: 48, height: 48)
                                            Image(systemName: "folder.fill")
                                                .font(.system(size: 22, weight: .bold))
                                                .foregroundColor(.emeraldAccent)
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Import from Files App")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.textPrimary)
                                            Text("Trim MP4, MOV, MKV, WebM from Downloads & iCloud")
                                                .font(.system(size: 12))
                                                .foregroundColor(.textMuted)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.textTertiary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 40)
                    } else {
                        // Player Card
                        ZStack(alignment: .topLeading) {
                            VideoPlayerView(player: playerModel.player)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.borderHairline, lineWidth: 1)
                                )

                            // Floating Mute Button (Top-Left)
                            Button(action: { playerModel.toggleMute() }) {
                                Image(systemName: playerModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(playerModel.isMuted ? Color(hex: "FF5252") : .white)
                                    .frame(width: 34, height: 34)
                                    .background(Color.black.opacity(0.75))
                                    .clipShape(Circle())
                            }
                            .padding(10)

                            // Resolution & Framerate Badge (Top-Right)
                            if let info = videoInfo {
                                HStack(spacing: 4) {
                                    Text("\(info.width) × \(info.height)")
                                    Text("•")
                                    Text(String(format: "%.0f FPS", info.fps))
                                }
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.emeraldAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.75))
                                .cornerRadius(6)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(10)
                            }
                        }
                        .padding(.horizontal, 16)

                        // Trimming Information & Timeline Card
                        if let info = videoInfo {
                            GlassCard(cornerRadius: 16, padding: 14) {
                                VStack(spacing: 12) {
                                    // Timecode & Duration Header
                                    HStack {
                                        Button(action: { activeTimecodeTarget = .playhead }) {
                                            HStack(spacing: 5) {
                                                Image(systemName: "clock.badge.checkmark")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.brandAccent)
                                                Text(playerModel.smpteTimecode(fps: info.fps))
                                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.textPrimary)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.elevatedSurface)
                                            .cornerRadius(6)
                                        }

                                        Spacer()

                                        let cutSec = Double(max(0, outPointMs - inPointMs)) / 1000.0
                                        let cutFrames = Int64(round(cutSec * info.fps))
                                        Text(String(format: "Cut: %.2fs (%lld frames)", cutSec, cutFrames))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.emeraldAccent)
                                    }

                                    // Timeline Micro-Zoom Controls (1x Overview, 5x Fine, 20x Micro)
                                    HStack(spacing: 6) {
                                        Text("Zoom:")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.textMuted)

                                        zoomPill("1x Overview", zoom: 1.0)
                                        zoomPill("5x Fine", zoom: 5.0)
                                        zoomPill("20x Micro", zoom: 20.0)

                                        Spacer()
                                    }

                                    // Interactive Master Playhead & Trim Scrubber
                                    VStack(spacing: 6) {
                                        GeometryReader { geo in
                                            let width = geo.size.width
                                            let duration = max(1, Double(info.durationMs))
                                            let inFraction = CGFloat(Double(inPointMs) / duration)
                                            let outFraction = CGFloat(Double(outPointMs) / duration)
                                            let playheadFraction = CGFloat(Double(playerModel.currentPositionMs) / duration)

                                            ZStack(alignment: .leading) {
                                                // Background Track
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(Color.elevatedSurface)
                                                    .frame(height: 6)

                                                // Active Trimming Range Highlight
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(Color.brandAccent.opacity(0.85))
                                                    .frame(width: max(2, (outFraction - inFraction) * width), height: 6)
                                                    .offset(x: inFraction * width)

                                                // Playhead Indicator
                                                Circle()
                                                    .fill(Color.white)
                                                    .frame(width: 14, height: 14)
                                                    .shadow(radius: 3)
                                                    .offset(x: max(0, min(width - 14, playheadFraction * width - 7)))
                                            }
                                            .contentShape(Rectangle())
                                            .gesture(
                                                DragGesture(minimumDistance: 0)
                                                    .onChanged { value in
                                                        let fraction = max(0, min(1, value.location.x / width))
                                                        let targetMs = Int64(fraction * duration)
                                                        playerModel.seek(to: targetMs)
                                                    }
                                            )
                                        }
                                        .frame(height: 18)

                                        // Magnified Micro-Scrubber when zoomed
                                        if timelineZoom > 1.0 {
                                            GeometryReader { geo in
                                                let width = geo.size.width
                                                let windowMs = max(500, Int64(Double(info.durationMs) / timelineZoom))
                                                let halfWin = windowMs / 2
                                                let winStart = max(0, min(info.durationMs - windowMs, playerModel.currentPositionMs - halfWin))
                                                let winEnd = winStart + windowMs
                                                let winDuration = max(1, Double(winEnd - winStart))

                                                let playheadRel = CGFloat(Double(playerModel.currentPositionMs - winStart) / winDuration)

                                                ZStack(alignment: .leading) {
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .fill(Color.surfaceCard)
                                                        .frame(height: 14)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 4)
                                                                .stroke(Color.skyAccent.opacity(0.3), lineWidth: 1)
                                                        )

                                                    // Center playhead bar
                                                    Rectangle()
                                                        .fill(Color.skyAccent)
                                                        .frame(width: 3, height: 14)
                                                        .offset(x: max(0, min(width - 3, playheadRel * width)))
                                                }
                                                .contentShape(Rectangle())
                                                .gesture(
                                                    DragGesture(minimumDistance: 0)
                                                        .onChanged { value in
                                                            let fraction = max(0, min(1, value.location.x / width))
                                                            let targetMs = winStart + Int64(fraction * winDuration)
                                                            playerModel.seek(to: targetMs)
                                                        }
                                                )
                                            }
                                            .frame(height: 14)
                                        }
                                    }

                                    // In-Point & Out-Point Selection Controls with Frame Nudging
                                    VStack(spacing: 8) {
                                        HStack(spacing: 6) {
                                            // Set IN
                                            Button(action: { inPointMs = min(playerModel.currentPositionMs, outPointMs - 100) }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "arrow.right.to.line")
                                                        .font(.system(size: 11))
                                                    Text("Set IN")
                                                        .font(.system(size: 12, weight: .bold))
                                                }
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(Color.elevatedSurface)
                                                .cornerRadius(8)
                                                .foregroundColor(.skyAccent)
                                            }

                                            // IN Nudge -1f / +1f
                                            nudgeButton("-1f") { nudgeIn(byFrames: -1, fps: info.fps) }
                                            nudgeButton("+1f") { nudgeIn(byFrames: 1, fps: info.fps) }

                                            Button(action: { activeTimecodeTarget = .inPoint }) {
                                                Text(formatMsToSMPTETimecode(inPointMs, fps: info.fps))
                                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.skyAccent)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 4)
                                                    .background(Color.elevatedSurface)
                                                    .cornerRadius(6)
                                            }
                                        }

                                        HStack(spacing: 6) {
                                            // Set OUT
                                            Button(action: { outPointMs = max(playerModel.currentPositionMs, inPointMs + 100) }) {
                                                HStack(spacing: 4) {
                                                    Text("Set OUT")
                                                        .font(.system(size: 12, weight: .bold))
                                                    Image(systemName: "arrow.left.to.line")
                                                        .font(.system(size: 11))
                                                }
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(Color.elevatedSurface)
                                                .cornerRadius(8)
                                                .foregroundColor(.gradientStart)
                                            }

                                            // OUT Nudge -1f / +1f
                                            nudgeButton("-1f") { nudgeOut(byFrames: -1, fps: info.fps, durationMs: info.durationMs) }
                                            nudgeButton("+1f") { nudgeOut(byFrames: 1, fps: info.fps, durationMs: info.durationMs) }

                                            Button(action: { activeTimecodeTarget = .outPoint }) {
                                                Text(formatMsToSMPTETimecode(outPointMs, fps: info.fps))
                                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.gradientStart)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 4)
                                                    .background(Color.elevatedSurface)
                                                    .cornerRadius(6)
                                            }
                                        }
                                    }

                                    // Transport Bar (Jump In, Play/Pause, Jump Out, Mute)
                                    HStack(spacing: 24) {
                                        Button(action: { playerModel.seek(to: inPointMs) }) {
                                            Image(systemName: "backward.end.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(.skyAccent)
                                        }

                                        Button(action: { playerModel.togglePlayPause() }) {
                                            ZStack {
                                                Circle()
                                                    .fill(LinearGradient.brandGradient)
                                                    .frame(width: 46, height: 46)
                                                Image(systemName: playerModel.isPlaying ? "pause.fill" : "play.fill")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(.white)
                                            }
                                        }

                                        Button(action: { playerModel.seek(to: outPointMs) }) {
                                            Image(systemName: "forward.end.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(.gradientStart)
                                        }

                                        Button(action: { playerModel.toggleMute() }) {
                                            Image(systemName: playerModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(playerModel.isMuted ? Color(hex: "FF5252") : .textMuted)
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .padding(.horizontal, 16)

                            // Audio Export Settings Card (Toggle Enable / Disable Audio on Export)
                            GlassCard(cornerRadius: 14, padding: 12) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(includeAudioInExport ? Color.emeraldAccent.opacity(0.15) : Color(hex: "FF5252").opacity(0.15))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: includeAudioInExport ? "music.note" : "speaker.slash")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(includeAudioInExport ? .emeraldAccent : Color(hex: "FF5252"))
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(includeAudioInExport ? "Include Audio Track" : "Mute Audio on Export")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.textPrimary)
                                        Text(includeAudioInExport ? "Keep original sound in exported clip" : "Export 100% silent video (audio stripped)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.textMuted)
                                    }

                                    Spacer()

                                    Toggle("", isOn: $includeAudioInExport)
                                        .labelsHidden()
                                        .tint(.emeraldAccent)
                                }
                            }
                            .padding(.horizontal, 16)

                            // Precision Cut Engine Selector
                            GlassCard(cornerRadius: 14, padding: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Precision Cut Engine")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.textPrimary)

                                        Spacer()

                                        Text(selectedPrecisionMode == .frameAccurate ? "1-Frame Accurate" : "Fast Stream Copy")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.emeraldAccent)
                                    }

                                    HStack(spacing: 6) {
                                        ForEach(TrimPrecisionMode.allCases) { mode in
                                            Button(action: {
                                                selectedPrecisionMode = mode
                                                playerModel.triggerHaptic()
                                            }) {
                                                Text(mode.rawValue)
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundColor(selectedPrecisionMode == mode ? .white : .textMuted)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(selectedPrecisionMode == mode ? Color.brandAccent : Color.elevatedSurface)
                                                    .cornerRadius(6)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)

                            // Export Progress with Active Stop Button
                            if isExporting {
                                GlassCard(cornerRadius: 14, padding: 14) {
                                    VStack(spacing: 10) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Trimming Clip...")
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundColor(.textPrimary)
                                                Text(String(format: "Progress: %.0f%%", exportProgress * 100.0))
                                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                    .foregroundColor(.emeraldAccent)
                                            }

                                            Spacer()

                                            Button(action: stopTrimProcess) {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "stop.circle.fill")
                                                        .font(.system(size: 14, weight: .bold))
                                                    Text("Stop")
                                                        .font(.system(size: 12, weight: .bold))
                                                }
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 7)
                                                .background(Color(hex: "FF453A"))
                                                .cornerRadius(8)
                                            }
                                        }

                                        ProgressView(value: exportProgress, total: 1.0)
                                            .progressViewStyle(LinearProgressViewStyle(tint: .brandAccent))
                                    }
                                }
                                .padding(.horizontal, 16)
                            }

                            // Export Action / Stop Button
                            if isExporting {
                                Button(action: stopTrimProcess) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "stop.fill")
                                            .font(.system(size: 16, weight: .bold))
                                        Text("Stop Trimming Process")
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(Color(hex: "FF453A"))
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                                .padding(.horizontal, 16)
                            } else {
                                Button(action: exportTrimmedVideo) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.system(size: 16, weight: .bold))
                                        Text(includeAudioInExport ? "Export Trimmed Video" : "Export Muted Video Clip")
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(LinearGradient.brandGradient)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                                .padding(.horizontal, 16)
                            }

                            // Share / Save to Files Button
                            if let _ = trimmedFileUrl {
                                Button(action: { showShareSheet = true }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.system(size: 15, weight: .bold))
                                        Text("Share / Save Trimmed Video to Files")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.elevatedSurface)
                                    .foregroundColor(.skyAccent)
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.skyAccent.opacity(0.4), lineWidth: 1)
                                    )
                                }
                                .padding(.horizontal, 16)
                            }

                            Spacer(minLength: 24)
                        }
                    }
                }
            }

            // Timecode Jump / Edit Modal
            if let target = activeTimecodeTarget, let info = videoInfo {
                let initial = (target == .inPoint) ? inPointMs : (target == .outPoint ? outPointMs : playerModel.currentPositionMs)
                TimecodeEntryModal(
                    target: target,
                    initialMs: initial,
                    durationMs: info.durationMs,
                    onApply: { newMs in
                        switch target {
                        case .inPoint:
                            inPointMs = min(newMs, outPointMs - 100)
                        case .outPoint:
                            outPointMs = max(newMs, inPointMs + 100)
                        case .playhead:
                            playerModel.seek(to: newMs)
                        }
                    },
                    onDismiss: { activeTimecodeTarget = nil }
                )
            }

            // Remuxing Matroska Movie Modal
            if isRemuxing {
                ZStack {
                    Color.black.opacity(0.85)
                        .ignoresSafeArea()

                    GlassCard(cornerRadius: 20, padding: 22) {
                        VStack(spacing: 16) {
                            HStack {
                                Image(systemName: "film.stack.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.brandAccent)

                                Text("Remuxing MKV Movie")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.textPrimary)

                                Spacer()

                                Text("\(Int(remuxProgress * 100))%")
                                    .font(.system(size: 22, weight: .black, design: .rounded))
                                    .foregroundColor(.brandAccent)
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.elevatedSurface)
                                        .frame(height: 8)

                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(LinearGradient.brandGradient)
                                        .frame(width: max(0, geo.size.width * CGFloat(remuxProgress)), height: 8)
                                        .animation(.linear(duration: 0.15), value: remuxProgress)
                                }
                            }
                            .frame(height: 8)

                            HStack {
                                Text(remuxSpeedText.isEmpty ? "Losslessly repackaging to MP4..." : "Stream Copying @ \(remuxSpeedText)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.emeraldAccent)

                                Spacer()

                                Text("0% Quality Loss")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.textMuted)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.elevatedSurface)
                                    .cornerRadius(4)
                            }

                            // Cancel Remux Button
                            Button(action: {
                                MKVRemuxEngine.shared.cancel()
                                isRemuxing = false
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Cancel Remux")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color(hex: "FF453A"))
                                .cornerRadius(8)
                            }
                        }
                        .frame(maxWidth: 300)
                    }
                }
                .transition(.opacity)
                .zIndex(99)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: selectedItem) { newItem in
            Task {
                if let item = newItem {
                    await loadVideo(from: item)
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [
                .movie,
                .video,
                .quickTimeMovie,
                .mpeg4Movie,
                UTType("org.webmproject.webm") ?? .movie,
                UTType("org.matroska.mkv") ?? .movie,
                UTType(filenameExtension: "webm") ?? .movie,
                UTType(filenameExtension: "mkv") ?? .movie,
                .item
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    loadFromFiles(url: url)
                }
            case .failure(let error):
                alertMessage = "File import error: \(error.localizedDescription)"
                showAlert = true
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let outUrl = trimmedFileUrl {
                ShareActivityView(activityItems: [outUrl])
            }
        }
        .alert(alertMessage ?? "", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    private func loadVideo(from item: PhotosPickerItem) async {
        do {
            if let movie = try await item.loadTransferable(type: MovieTransferable.self) {
                let url = movie.url
                let info = try await VideoEngine.shared.extractVideoInfo(from: url)
                await MainActor.run {
                    self.videoUrl = url
                    self.videoInfo = info
                    self.inPointMs = 0
                    self.outPointMs = info.durationMs
                    self.playerModel.setup(with: url) { ms in
                        if self.outPointMs > 0 && ms >= self.outPointMs && self.playerModel.isPlaying {
                            self.playerModel.seek(to: self.inPointMs)
                        }
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.alertMessage = "Failed to load video: \(error.localizedDescription)"
                self.showAlert = true
            }
        }
    }

    private func loadFromFiles(url: URL) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if isSecurityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            var workingUrl: URL

            if MKVRemuxEngine.shared.isMatroska(url: url) {
                await MainActor.run {
                    self.isRemuxing = true
                    self.remuxProgress = 0.0
                    self.remuxSpeedText = "Direct Stream Copy..."
                }
                do {
                    workingUrl = try await MKVRemuxEngine.shared.remuxToMP4(sourceUrl: url) { progress, speed in
                        Task { @MainActor in
                            self.remuxProgress = progress
                            self.remuxSpeedText = speed
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isRemuxing = false
                        self.alertMessage = "Failed to remux Matroska movie: \(error.localizedDescription)"
                        self.showAlert = true
                    }
                    return
                }
                await MainActor.run {
                    self.isRemuxing = false
                }
            } else {
                let tempDir = FileManager.default.temporaryDirectory
                let destUrl = tempDir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: destUrl)
                do {
                    try FileManager.default.copyItem(at: url, to: destUrl)
                    workingUrl = destUrl
                } catch {
                    await MainActor.run {
                        self.alertMessage = "Failed to access file: \(error.localizedDescription)"
                        self.showAlert = true
                    }
                    return
                }
            }

            do {
                let info = try await VideoEngine.shared.extractVideoInfo(from: workingUrl)
                await MainActor.run {
                    self.videoUrl = workingUrl
                    self.videoInfo = info
                    self.inPointMs = 0
                    self.outPointMs = info.durationMs
                    self.playerModel.setup(with: workingUrl) { ms in
                        if self.outPointMs > 0 && ms >= self.outPointMs && self.playerModel.isPlaying {
                            self.playerModel.seek(to: self.inPointMs)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = "Failed to load video: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    private func zoomPill(_ title: String, zoom: Double) -> some View {
        Button(action: {
            timelineZoom = zoom
            playerModel.triggerHaptic()
        }) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(timelineZoom == zoom ? .white : .textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(timelineZoom == zoom ? Color.skyAccent : Color.elevatedSurface)
                .cornerRadius(4)
        }
    }

    private func nudgeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.elevatedSurface)
                .cornerRadius(6)
        }
    }

    private func nudgeIn(byFrames delta: Int64, fps: Double) {
        playerModel.triggerHaptic()
        let frameMs = Int64(round(1000.0 / max(1.0, fps)))
        let target = inPointMs + (delta * frameMs)
        inPointMs = max(0, min(target, outPointMs - 100))
        playerModel.seek(to: inPointMs)
    }

    private func nudgeOut(byFrames delta: Int64, fps: Double, durationMs: Int64) {
        playerModel.triggerHaptic()
        let frameMs = Int64(round(1000.0 / max(1.0, fps)))
        let target = outPointMs + (delta * frameMs)
        outPointMs = min(durationMs, max(target, inPointMs + 100))
        playerModel.seek(to: outPointMs)
    }

    private func stopTrimProcess() {
        VideoTrimEngine.shared.cancel()
        playerModel.triggerHaptic()
        isExporting = false
        exportProgress = 0.0
    }

    private func exportTrimmedVideo() {
        guard let url = videoUrl, !isExporting else { return }
        isExporting = true
        exportProgress = 0.0

        Task {
            let result = await VideoTrimEngine.shared.trimVideo(
                srcUrl: url,
                startMs: inPointMs,
                endMs: outPointMs,
                includeAudio: includeAudioInExport,
                mode: selectedPrecisionMode,
                onProgress: { p in
                    self.exportProgress = p
                }
            )

            await MainActor.run {
                self.isExporting = false
                if result.errorMessage == "OPERATION_CANCELLED" {
                    // User tapped Stop — reset cleanly without error popups
                    return
                }
                if result.success, let outUrl = result.outputUrl {
                    self.trimmedFileUrl = outUrl
                    if result.errorMessage != nil {
                        // Automatically open Save to Files / Share Sheet!
                        self.showShareSheet = true
                    } else {
                        self.alertMessage = includeAudioInExport ? "✓ Trimmed video saved to Camera Roll!" : "✓ Trimmed silent video saved to Camera Roll!"
                        self.showAlert = true
                    }
                } else {
                    self.alertMessage = "Export Error: \(result.errorMessage ?? "Unknown error")"
                    self.showAlert = true
                }
            }
        }
    }
}

// Transferable helper for iOS PhotosPicker video loading
struct MovieTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copyUrl = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copyUrl)
            try FileManager.default.copyItem(at: received.file, to: copyUrl)
            return Self(url: copyUrl)
        }
    }
}
