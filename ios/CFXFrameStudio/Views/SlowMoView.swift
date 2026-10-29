import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct SlowMoView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var playerModel = PlayerModel()

    @State private var selectedPhotosItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false

    // Source Video State
    @State private var sourceVideoUrl: URL? = nil
    @State private var sourceVideoInfo: VideoInfo? = nil

    // Applied Smooth Slow-Mo Video State
    @State private var appliedSlowMoUrl: URL? = nil
    @State private var appliedVideoInfo: VideoInfo? = nil

    enum VideoDisplayMode: String, CaseIterable, Identifiable {
        case appliedSlowMo = "✨ Applied Slow-Mo"
        case original = "📹 Original Video"
        var id: String { rawValue }
    }
    @State private var activeDisplayMode: VideoDisplayMode = .original

    // Slow-Mo Settings
    @State private var speedPercentage: Double = 25.0 // Default 25% (4x slow motion)
    @State private var targetFps: Int = 60
    @State private var selectedInterpolation: SlowMoInterpolationMode = .opticalFlow
    @State private var selectedAudioMode: SlowMoAudioMode = .pitchPreserved

    // Collapsible Sections State
    @State private var isSpeedSectionExpanded: Bool = true
    @State private var isEngineSectionExpanded: Bool = false
    @State private var isAudioFpsSectionExpanded: Bool = false
    @State private var isRangeSectionExpanded: Bool = false

    // Sub-range trimming
    @State private var inPointMs: Int64 = 0
    @State private var outPointMs: Int64 = 0

    // Processing & Progress
    @State private var isProcessing: Bool = false
    @State private var processProgress: Double = 0.0
    @State private var processSpeedText: String = ""
    @State private var isExportingToPhotos: Bool = false
    @State private var showShareSheet: Bool = false

    // Remuxing MKV Staging
    @State private var isRemuxing: Bool = false
    @State private var remuxProgress: Double = 0.0
    @State private var remuxSpeedText: String = ""

    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    private let speedPresets: [(label: String, pct: Double)] = [
        ("50% (2x)", 50.0),
        ("40% (2.5x)", 40.0),
        ("25% (4x)", 25.0),
        ("12.5% (8x)", 12.5),
        ("10% (10x)", 10.0)
    ]

    private var activeVideoInfo: VideoInfo? {
        if activeDisplayMode == .appliedSlowMo, let applied = appliedVideoInfo {
            return applied
        }
        return sourceVideoInfo
    }

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    // Header Bar
                    headerBar

                    if sourceVideoUrl == nil {
                        // Empty State: Dual Import Options
                        emptyStatePicker
                    } else if let info = activeVideoInfo {
                        // 1. Video Player Container
                        playerCard(info: info)

                        // 2. Applied Slow-Mo vs Original Video Switcher (if applied)
                        if appliedSlowMoUrl != nil {
                            displayModeSwitcher
                        }

                        // 3. Transport, Timeline Scrubber & IN/OUT Markers
                        transportAndScrubberCard(info: info)

                        // 4. Primary Actions (Apply Preview or Export)
                        primaryActionsCard(info: info)

                        // 5. Collapsible Studio Settings Cards
                        collapsibleSpeedCard(info: info)
                        collapsibleEngineCard
                        collapsibleAudioAndFpsCard
                        collapsibleRangeCard(info: info)

                        Spacer(minLength: 28)
                    }
                }
                .padding(.bottom, 20)
            }

            // Remuxing MKV Modal
            if isRemuxing {
                remuxModal
            }
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: selectedPhotosItem) { newItem in
            Task {
                if let item = newItem {
                    await loadVideo(from: item)
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: UTType.supportedVideoImportTypes,
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
            if let outUrl = appliedSlowMoUrl {
                ShareActivityView(activityItems: [outUrl])
            }
        }
        .alert(alertMessage ?? "", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
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

            Text("SMOOTH SLOW-MO STUDIO")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.textPrimary)

            Spacer()

            if sourceVideoUrl != nil {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $selectedPhotosItem, matching: .videos) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .frame(width: 36, height: 36)
                            .background(Color.surfaceCard)
                            .clipShape(Circle())
                    }

                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .frame(width: 36, height: 36)
                            .background(Color.surfaceCard)
                            .clipShape(Circle())
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Empty State

    private var emptyStatePicker: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $selectedPhotosItem, matching: .videos) {
                GlassCard(cornerRadius: 18, padding: 22) {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.brandAccent.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.brandAccent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Import from Camera Roll")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.textPrimary)
                            Text("Photos library videos (24, 30, 60, 120, 240fps)")
                                .font(.system(size: 12))
                                .foregroundColor(.textMuted)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.textTertiary)
                    }
                }
            }

            Button(action: { showFilePicker = true }) {
                GlassCard(cornerRadius: 18, padding: 22) {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.skyAccent.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: "folder.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.skyAccent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Import from Files App")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.textPrimary)
                            Text("MP4, MOV, MKV, WebM from Downloads & iCloud")
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
    }

    // MARK: - Video Player Card

    @ViewBuilder
    private func playerCard(info: VideoInfo) -> some View {
        ZStack(alignment: .topLeading) {
            VideoPlayerView(player: playerModel.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(activeDisplayMode == .appliedSlowMo ? Color.emeraldAccent.opacity(0.6) : Color.borderHairline, lineWidth: activeDisplayMode == .appliedSlowMo ? 1.5 : 1)
                )

            // Floating Mute Button
            Button(action: { playerModel.toggleMute() }) {
                Image(systemName: playerModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(playerModel.isMuted ? Color(hex: "FF5252") : .white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.75))
                    .clipShape(Circle())
            }
            .padding(10)

            // Status Badge
            HStack(spacing: 4) {
                if activeDisplayMode == .appliedSlowMo {
                    Circle().fill(Color.emeraldAccent).frame(width: 6, height: 6)
                    Text("APPLIED SLOW-MO")
                        .foregroundColor(.emeraldAccent)
                    Text("•")
                        .foregroundColor(.textTertiary)
                }
                Text("\(info.width) × \(info.height)")
                Text("•")
                Text(String(format: "%.0f FPS", info.fps))
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.emeraldAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.85))
            .cornerRadius(6)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(10)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Display Mode Switcher (Applied Slow-Mo vs Original)

    private var displayModeSwitcher: some View {
        HStack(spacing: 8) {
            // Applied Slow-Mo Tab
            Button(action: {
                guard activeDisplayMode != .appliedSlowMo, let appliedUrl = appliedSlowMoUrl, let appliedInfo = appliedVideoInfo else { return }
                activeDisplayMode = .appliedSlowMo
                playerModel.triggerHaptic()
                switchPlayerTo(url: appliedUrl, info: appliedInfo, isApplied: true)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                    Text("Applied Slow-Mo Preview")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(activeDisplayMode == .appliedSlowMo ? .white : .textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(activeDisplayMode == .appliedSlowMo ? Color.emeraldAccent : Color.surfaceCard)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(activeDisplayMode == .appliedSlowMo ? Color.emeraldAccent.opacity(0.5) : Color.borderHairline, lineWidth: 1)
                )
            }

            // Original Source Tab
            Button(action: {
                guard activeDisplayMode != .original, let sourceUrl = sourceVideoUrl, let sourceInfo = sourceVideoInfo else { return }
                activeDisplayMode = .original
                playerModel.triggerHaptic()
                switchPlayerTo(url: sourceUrl, info: sourceInfo, isApplied: false)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 12, weight: .bold))
                    Text("Original Video")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(activeDisplayMode == .original ? .white : .textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(activeDisplayMode == .original ? Color.skyAccent : Color.surfaceCard)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(activeDisplayMode == .original ? Color.skyAccent.opacity(0.5) : Color.borderHairline, lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Transport & Scrubber Card

    @ViewBuilder
    private func transportAndScrubberCard(info: VideoInfo) -> some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(spacing: 12) {
                // Timecode Header
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
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

                    Spacer()

                    if activeDisplayMode == .appliedSlowMo {
                        Text(String(format: "Slow-Mo Duration: %.1fs", Double(info.durationMs) / 1000.0))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.emeraldAccent)
                    } else {
                        let clipDurationSec = Double(max(100, outPointMs - inPointMs)) / 1000.0
                        let outputDurationSec = clipDurationSec * (100.0 / speedPercentage)
                        HStack(spacing: 4) {
                            Text(String(format: "%.1fs Clip", clipDurationSec))
                                .foregroundColor(.textMuted)
                            Text("→")
                                .foregroundColor(.textTertiary)
                            Text(String(format: "%.1fs Slow-Mo", outputDurationSec))
                                .foregroundColor(.emeraldAccent)
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }

                // Interactive Scrubber Bar
                GeometryReader { geo in
                    let width = geo.size.width
                    let duration = max(1, Double(info.durationMs))
                    let inFrac = (activeDisplayMode == .appliedSlowMo) ? 0.0 : CGFloat(Double(inPointMs) / duration)
                    let outFrac = (activeDisplayMode == .appliedSlowMo) ? 1.0 : CGFloat(Double(outPointMs) / duration)
                    let playheadFrac = CGFloat(Double(playerModel.currentPositionMs) / duration)

                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.elevatedSurface)
                            .frame(height: 6)

                        // Highlighted IN -> OUT range
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient.brandGradient)
                            .frame(width: max(2, (outFrac - inFrac) * width), height: 6)
                            .offset(x: inFrac * width)

                        // Playhead indicator
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: Color.brandAccent.opacity(0.6), radius: 4)
                            .offset(x: max(0, min(width - 14, playheadFrac * width - 7)))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let frac = max(0, min(1, value.location.x / width))
                                let targetMs = Int64(frac * duration)
                                playerModel.seek(to: targetMs, preservePlaybackState: true)
                            }
                    )
                }
                .frame(height: 16)

                // Master Transport Controls Bar
                HStack(spacing: 8) {
                    // Jump to IN / Start
                    Button(action: {
                        playerModel.triggerHaptic()
                        let jumpMs = (activeDisplayMode == .appliedSlowMo) ? 0 : inPointMs
                        playerModel.seek(to: jumpMs, preservePlaybackState: true)
                    }) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Color.elevatedSurface)
                            .cornerRadius(6)
                    }

                    if activeDisplayMode == .original {
                        // Set IN
                        Button(action: {
                            inPointMs = min(playerModel.currentPositionMs, max(0, outPointMs - 100))
                            playerModel.triggerHaptic()
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.right.to.line")
                                Text("IN")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.elevatedSurface)
                            .cornerRadius(6)
                            .foregroundColor(.skyAccent)
                        }
                    }

                    // Main Play / Pause Button
                    Button(action: togglePlayPause) {
                        HStack(spacing: 6) {
                            Image(systemName: playerModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                            Text(playerModel.isPlaying ? "Pause" : (activeDisplayMode == .appliedSlowMo ? "Play Slow-Mo" : "Play"))
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(minWidth: 100, minHeight: 34)
                        .background(LinearGradient.brandGradient)
                        .cornerRadius(8)
                        .shadow(color: Color.brandAccent.opacity(playerModel.isPlaying ? 0.4 : 0.0), radius: 6)
                    }

                    if activeDisplayMode == .original {
                        // Set OUT
                        Button(action: {
                            outPointMs = max(playerModel.currentPositionMs, inPointMs + 100)
                            playerModel.triggerHaptic()
                        }) {
                            HStack(spacing: 3) {
                                Text("OUT")
                                    .font(.system(size: 11, weight: .bold))
                                Image(systemName: "arrow.left.to.line")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.elevatedSurface)
                            .cornerRadius(6)
                            .foregroundColor(.gradientStart)
                        }
                    }

                    // Jump to OUT / End
                    Button(action: {
                        playerModel.triggerHaptic()
                        let jumpMs = (activeDisplayMode == .appliedSlowMo) ? (appliedVideoInfo?.durationMs ?? 0) : outPointMs
                        playerModel.seek(to: jumpMs, preservePlaybackState: true)
                    }) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Color.elevatedSurface)
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Primary Action Card (Apply vs Export)

    @ViewBuilder
    private func primaryActionsCard(info: VideoInfo) -> some View {
        VStack(spacing: 10) {
            // Processing Card with Active Stop Button
            if isProcessing {
                GlassCard(cornerRadius: 14, padding: 14) {
                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Synthesizing Optical Flow Frames...")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.textPrimary)
                                Text(processSpeedText.isEmpty ? String(format: "Progress: %.0f%%", processProgress * 100.0) : "\(String(format: "%.0f%%", processProgress * 100.0)) @ \(processSpeedText)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.emeraldAccent)
                            }

                            Spacer()

                            Button(action: stopProcess) {
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

                        ProgressView(value: processProgress)
                            .tint(.brandAccent)
                    }
                }
                .padding(.horizontal, 16)
            } else if appliedSlowMoUrl != nil {
                // Applied State: Prominent Export & Share Controls
                VStack(spacing: 10) {
                    // Export / Save to Photos Camera Roll Button
                    Button(action: exportAppliedVideoToPhotos) {
                        HStack(spacing: 8) {
                            if isExportingToPhotos {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down.fill")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            Text(isExportingToPhotos ? "Saving to Camera Roll..." : "Export & Save to Camera Roll")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "00B4DB"), Color(hex: "0083B0")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                        .shadow(color: Color(hex: "0083B0").opacity(0.35), radius: 8)
                    }
                    .disabled(isExportingToPhotos)

                    HStack(spacing: 8) {
                        // Share Sheet Button
                        Button(action: { showShareSheet = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share / Files")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Color.elevatedSurface)
                            .cornerRadius(10)
                        }

                        // Re-apply / Re-render Button
                        Button(action: applySlowMotionPreview) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Re-Apply Slow-Mo")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Color.surfaceCard)
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal, 16)
            } else {
                // Initial State: Apply Smooth Slow-Mo Button
                Button(action: applySlowMotionPreview) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 16, weight: .bold))
                        Text("Apply Smooth Slow-Mo (Preview)")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(LinearGradient.brandGradient)
                    .cornerRadius(12)
                    .shadow(color: Color.brandAccent.opacity(0.35), radius: 8)
                }
                .disabled(isProcessing)
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Collapsible 1: Speed & Presets

    @ViewBuilder
    private func collapsibleSpeedCard(info: VideoInfo) -> some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // Accordion Header
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isSpeedSectionExpanded.toggle()
                    }
                }) {
                    HStack {
                        Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .frame(width: 20)

                        Text("SLOW-MO SPEED")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .tracking(0.8)

                        Spacer()

                        Text(String(format: "%.1f%% (%.1fx Slow)", speedPercentage, 100.0 / speedPercentage))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.brandAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.elevatedSurface)
                            .cornerRadius(6)

                        Image(systemName: isSpeedSectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textTertiary)
                    }
                    .contentShape(Rectangle())
                }

                if isSpeedSectionExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        // Preset Buttons
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(speedPresets, id: \.pct) { preset in
                                    Button(action: {
                                        speedPercentage = preset.pct
                                        playerModel.triggerHaptic()
                                    }) {
                                        Text(preset.label)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(speedPercentage == preset.pct ? .white : .textMuted)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(speedPercentage == preset.pct ? Color.brandAccent : Color.elevatedSurface)
                                            .cornerRadius(6)
                                    }
                                }
                            }
                        }

                        // Fine Continuous Slider (1.0% to 100.0%)
                        VStack(spacing: 4) {
                            Slider(value: $speedPercentage, in: 1.0...100.0, step: 0.5)
                                .tint(.brandAccent)

                            HStack {
                                Text("1% (100x Ultra)")
                                Spacer()
                                Text("50% (2x)")
                                Spacer()
                                Text("100% (Normal)")
                            }
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.textTertiary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Collapsible 2: Motion Interpolation Engine

    @ViewBuilder
    private var collapsibleEngineCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // Accordion Header
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isEngineSectionExpanded.toggle()
                    }
                }) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .frame(width: 20)

                        Text("INTERPOLATION ENGINE")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .tracking(0.8)

                        Spacer()

                        Text(selectedInterpolation.rawValue.components(separatedBy: " ").first ?? "")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.emeraldAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.elevatedSurface)
                            .cornerRadius(6)

                        Image(systemName: isEngineSectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textTertiary)
                    }
                    .contentShape(Rectangle())
                }

                if isEngineSectionExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(SlowMoInterpolationMode.allCases) { mode in
                                    Button(action: {
                                        selectedInterpolation = mode
                                        playerModel.triggerHaptic()
                                    }) {
                                        Text(mode.rawValue)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(selectedInterpolation == mode ? .white : .textMuted)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(selectedInterpolation == mode ? Color.brandAccent : Color.elevatedSurface)
                                            .cornerRadius(6)
                                    }
                                }
                            }
                        }

                        Text(selectedInterpolation.description)
                            .font(.system(size: 11))
                            .foregroundColor(.textMuted)
                            .lineLimit(2)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Collapsible 3: Audio & Target Framerate

    @ViewBuilder
    private var collapsibleAudioAndFpsCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // Accordion Header
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isAudioFpsSectionExpanded.toggle()
                    }
                }) {
                    HStack {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .frame(width: 20)

                        Text("AUDIO & TARGET FPS")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .tracking(0.8)

                        Spacer()

                        Text("\(targetFps) FPS • \(selectedAudioMode.rawValue)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.skyAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.elevatedSurface)
                            .cornerRadius(6)

                        Image(systemName: isAudioFpsSectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textTertiary)
                    }
                    .contentShape(Rectangle())
                }

                if isAudioFpsSectionExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        // Framerate Selector
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TARGET OUTPUT FRAMERATE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.textTertiary)
                                .tracking(1.0)

                            HStack(spacing: 6) {
                                fpsPill(60, label: "60 FPS (Ultra Smooth)")
                                fpsPill(30, label: "30 FPS")
                                fpsPill(24, label: "24 FPS (Cinematic)")
                            }
                        }

                        Divider().background(Color.borderHairline)

                        // Audio Mode Selector
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AUDIO RETIMING MODE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.textTertiary)
                                .tracking(1.0)

                            HStack(spacing: 6) {
                                ForEach(SlowMoAudioMode.allCases) { mode in
                                    Button(action: {
                                        selectedAudioMode = mode
                                        playerModel.triggerHaptic()
                                    }) {
                                        Text(mode.rawValue)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(selectedAudioMode == mode ? .white : .textMuted)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(selectedAudioMode == mode ? Color.skyAccent : Color.elevatedSurface)
                                            .cornerRadius(6)
                                    }
                                }
                            }

                            Text(selectedAudioMode.description)
                                .font(.system(size: 11))
                                .foregroundColor(.textMuted)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func fpsPill(_ fps: Int, label: String) -> some View {
        Button(action: {
            targetFps = fps
            playerModel.triggerHaptic()
        }) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(targetFps == fps ? .white : .textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(targetFps == fps ? Color.emeraldAccent : Color.elevatedSurface)
                .cornerRadius(6)
        }
    }

    // MARK: - Collapsible 4: Range & Trim Markers

    @ViewBuilder
    private func collapsibleRangeCard(info: VideoInfo) -> some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // Accordion Header
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isRangeSectionExpanded.toggle()
                    }
                }) {
                    HStack {
                        Image(systemName: "scissors")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .frame(width: 20)

                        Text("RANGE MARKERS")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .tracking(0.8)

                        Spacer()

                        let clipDurationSec = Double(max(100, outPointMs - inPointMs)) / 1000.0
                        Text(String(format: "%.1fs Clip", clipDurationSec))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.emeraldAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.elevatedSurface)
                            .cornerRadius(6)

                        Image(systemName: isRangeSectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textTertiary)
                    }
                    .contentShape(Rectangle())
                }

                if isRangeSectionExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("IN POINT")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.textMuted)
                                Text(String(format: "%.2fs", Double(inPointMs) / 1000.0))
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.skyAccent)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("OUT POINT")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.textMuted)
                                Text(String(format: "%.2fs", Double(outPointMs) / 1000.0))
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gradientStart)
                            }
                        }

                        if let sourceInfo = sourceVideoInfo {
                            Button(action: {
                                inPointMs = 0
                                outPointMs = sourceInfo.durationMs
                                playerModel.triggerHaptic()
                            }) {
                                Text("Reset to Full Video")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(Color.elevatedSurface)
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Remuxing Modal

    private var remuxModal: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.brandAccent)

                Text("Optimizing Media for iOS")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text("Stream copying and preparing video for Apple iOS playback...")
                    .font(.system(size: 12))
                    .foregroundColor(.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if remuxProgress > 0 {
                    ProgressView(value: remuxProgress)
                        .tint(.brandAccent)
                        .padding(.horizontal, 32)
                }

                Button(action: {
                    MKVRemuxEngine.shared.cancel()
                    isRemuxing = false
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Cancel Optimization")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: "FF453A"))
                    .cornerRadius(8)
                }
            }
            .padding(24)
            .background(Color.surfaceCard)
            .cornerRadius(16)
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Playback Logic & Actions

    private func togglePlayPause() {
        playerModel.triggerHaptic()
        if playerModel.isPlaying {
            playerModel.pause()
        } else {
            let maxDuration = (activeDisplayMode == .appliedSlowMo) ? (appliedVideoInfo?.durationMs ?? 0) : outPointMs
            if playerModel.currentPositionMs >= maxDuration {
                let startPos = (activeDisplayMode == .appliedSlowMo) ? 0 : inPointMs
                playerModel.seek(to: startPos, preservePlaybackState: true)
            }
            playerModel.play(rate: 1.0)
        }
    }

    private func stopProcess() {
        SlowMoEngine.shared.cancel()
        playerModel.triggerHaptic()
        isProcessing = false
        processProgress = 0.0
    }

    private func applySlowMotionPreview() {
        guard let url = sourceVideoUrl, !isProcessing else { return }
        isProcessing = true
        processProgress = 0.0
        processSpeedText = "Calculating motion vectors..."
        playerModel.pause()
        playerModel.triggerHaptic()

        Task {
            let result = await SlowMoEngine.shared.createSlowMotion(
                sourceUrl: url,
                speedPercentage: speedPercentage,
                targetFps: targetFps,
                interpolationMode: selectedInterpolation,
                audioMode: selectedAudioMode,
                inPointMs: inPointMs,
                outPointMs: outPointMs,
                totalSourceDurationMs: sourceVideoInfo?.durationMs ?? 0
            ) { progress, speed in
                Task { @MainActor in
                    self.processProgress = progress
                    self.processSpeedText = speed
                }
            }

            await MainActor.run {
                self.isProcessing = false
                if result.success, let outputUrl = result.outputUrl {
                    Task {
                        if let newInfo = try? await VideoEngine.shared.extractVideoInfo(from: outputUrl) {
                            await MainActor.run {
                                self.appliedSlowMoUrl = outputUrl
                                self.appliedVideoInfo = newInfo
                                self.activeDisplayMode = .appliedSlowMo
                                self.switchPlayerTo(url: outputUrl, info: newInfo, isApplied: true)
                                self.playerModel.triggerHaptic()
                                // Auto-start preview of applied slow motion
                                self.playerModel.play(rate: 1.0)
                            }
                        }
                    }
                } else if let error = result.errorMessage, error != "OPERATION_CANCELLED" {
                    self.alertMessage = error
                    self.showAlert = true
                }
            }
        }
    }

    private func exportAppliedVideoToPhotos() {
        guard let url = appliedSlowMoUrl, !isExportingToPhotos else { return }
        isExportingToPhotos = true
        playerModel.triggerHaptic()

        Task {
            var success = false
            do {
                success = try await SlowMoEngine.shared.exportToPhotos(fileUrl: url)
            } catch {
                success = false
            }

            await MainActor.run {
                self.isExportingToPhotos = false
                if success {
                    self.alertMessage = "Smooth Slow-Mo video successfully exported to Photos Camera Roll!"
                    self.showAlert = true
                } else {
                    self.showShareSheet = true
                }
            }
        }
    }

    private func loadVideo(from item: PhotosPickerItem) async {
        do {
            if let movie = try await item.loadTransferable(type: MovieTransferable.self) {
                var url = movie.url
                if await MKVRemuxEngine.shared.requiresRemuxing(url: url) {
                    await MainActor.run {
                        self.isRemuxing = true
                        self.remuxProgress = 0.0
                        self.remuxSpeedText = "Optimizing for iOS playback..."
                    }
                    do {
                        url = try await MKVRemuxEngine.shared.remuxToMP4(sourceUrl: url) { progress, speed in
                            Task { @MainActor in
                                self.remuxProgress = progress
                                self.remuxSpeedText = speed
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.isRemuxing = false
                            self.alertMessage = "Failed to optimize video: \(error.localizedDescription)"
                            self.showAlert = true
                        }
                        return
                    }
                    await MainActor.run {
                        self.isRemuxing = false
                    }
                }

                let info = try await VideoEngine.shared.extractVideoInfo(from: url)
                await MainActor.run {
                    self.sourceVideoUrl = url
                    self.sourceVideoInfo = info
                    self.appliedSlowMoUrl = nil
                    self.appliedVideoInfo = nil
                    self.activeDisplayMode = .original
                    self.inPointMs = 0
                    self.outPointMs = info.durationMs
                    self.switchPlayerTo(url: url, info: info, isApplied: false)
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

            if await MKVRemuxEngine.shared.requiresRemuxing(url: url) {
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
                        self.alertMessage = "Failed to optimize video: \(error.localizedDescription)"
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
                    self.sourceVideoUrl = workingUrl
                    self.sourceVideoInfo = info
                    self.appliedSlowMoUrl = nil
                    self.appliedVideoInfo = nil
                    self.activeDisplayMode = .original
                    self.inPointMs = 0
                    self.outPointMs = info.durationMs
                    self.switchPlayerTo(url: workingUrl, info: info, isApplied: false)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = "Failed to load video: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    private func switchPlayerTo(url: URL, info: VideoInfo, isApplied: Bool) {
        playerModel.setup(with: url) { [weak playerModel] currentMs in
            guard let playerModel = playerModel else { return }
            if isApplied {
                if currentMs >= info.durationMs && playerModel.isPlaying {
                    playerModel.seek(to: 0, preservePlaybackState: true)
                }
            } else {
                let limitMs = self.outPointMs > 0 ? self.outPointMs : info.durationMs
                if currentMs >= limitMs && playerModel.isPlaying {
                    playerModel.seek(to: self.inPointMs, preservePlaybackState: true)
                }
            }
        }
    }
}
