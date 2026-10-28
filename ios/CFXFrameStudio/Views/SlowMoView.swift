import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct SlowMoView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var playerModel = PlayerModel()

    @State private var selectedPhotosItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false
    @State private var videoUrl: URL? = nil
    @State private var videoInfo: VideoInfo? = nil

    // Slow-Mo Retiming Controls
    @State private var speedPercentage: Double = 25.0 // Default 25% (4x slow motion)
    @State private var targetFps: Int = 60
    @State private var selectedInterpolation: SlowMoInterpolationMode = .opticalFlow
    @State private var selectedAudioMode: SlowMoAudioMode = .pitchPreserved

    // Sub-range trimming
    @State private var inPointMs: Int64 = 0
    @State private var outPointMs: Int64 = 0

    // Processing & Progress
    @State private var isProcessing: Bool = false
    @State private var processProgress: Double = 0.0
    @State private var processSpeedText: String = ""
    @State private var exportedFileUrl: URL? = nil
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

                        Text("SMOOTH SLOW-MO STUDIO")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Spacer()

                        if videoUrl != nil {
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

                    if videoUrl == nil {
                        // Empty State: Dual Import Options
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
                    } else {
                        // Video Player Card with Live Rate
                        ZStack(alignment: .topLeading) {
                            VideoPlayerView(player: playerModel.player)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.borderHairline, lineWidth: 1)
                                )

                            // Floating Mute Button
                            Button(action: { playerModel.toggleMute() }) {
                                Image(systemName: playerModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(playerModel.isMuted ? Color(hex: "FF5252") : .white)
                                    .frame(width: 34, height: 34)
                                    .background(Color.black.opacity(0.75))
                                    .clipShape(Circle())
                            }
                            .padding(10)

                            // Resolution & Source FPS Badge
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

                        // Transport & Range Card
                        if let info = videoInfo {
                            rangeAndTransportCard(info: info)
                            speedControlCard(info: info)
                            interpolationCard
                            audioAndFramerateCard
                            actionSection(info: info)
                            Spacer(minLength: 24)
                        }
                    }
                }
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
            if let outUrl = exportedFileUrl {
                ShareActivityView(activityItems: [outUrl])
            }
        }
        .alert(alertMessage ?? "", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func rangeAndTransportCard(info: VideoInfo) -> some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(spacing: 12) {
                // Header: Current SMPTE & Active Range
                HStack {
                    HStack(spacing: 5) {
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

                    let clipDurationSec = Double(max(100, outPointMs - inPointMs)) / 1000.0
                    let outputDurationSec = clipDurationSec * (100.0 / speedPercentage)
                    Text(String(format: "In: %.1fs → Out: %.1fs", clipDurationSec, outputDurationSec))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.emeraldAccent)
                }

                // Interactive Scrubber
                GeometryReader { geo in
                    let width = geo.size.width
                    let duration = max(1, Double(info.durationMs))
                    let inFrac = CGFloat(Double(inPointMs) / duration)
                    let outFrac = CGFloat(Double(outPointMs) / duration)
                    let playheadFrac = CGFloat(Double(playerModel.currentPositionMs) / duration)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.elevatedSurface)
                            .frame(height: 6)

                        // Highlighted Range
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.brandAccent.opacity(0.85))
                            .frame(width: max(2, (outFrac - inFrac) * width), height: 6)
                            .offset(x: inFrac * width)

                        // Playhead
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(radius: 3)
                            .offset(x: max(0, min(width - 14, playheadFrac * width - 7)))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let frac = max(0, min(1, value.location.x / width))
                                let targetMs = Int64(frac * duration)
                                playerModel.seek(to: targetMs)
                            }
                    )
                }
                .frame(height: 18)

                // Range Set Buttons
                HStack(spacing: 8) {
                    Button(action: {
                        inPointMs = min(playerModel.currentPositionMs, outPointMs - 100)
                        playerModel.triggerHaptic()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.to.line")
                            Text("Set IN")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.elevatedSurface)
                        .cornerRadius(6)
                        .foregroundColor(.skyAccent)
                    }

                    Button(action: {
                        playerModel.seek(to: inPointMs)
                        togglePlayPause()
                    }) {
                        Image(systemName: playerModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 32)
                            .background(LinearGradient.brandGradient)
                            .cornerRadius(8)
                    }

                    Button(action: {
                        outPointMs = max(playerModel.currentPositionMs, inPointMs + 100)
                        playerModel.triggerHaptic()
                    }) {
                        HStack(spacing: 4) {
                            Text("Set OUT")
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
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func speedControlCard(info: VideoInfo) -> some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SLOW-MO SPEED")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textTertiary)
                            .tracking(1.0)

                        let slowMultiplier = 100.0 / speedPercentage
                        Text(String(format: "%.1f%% Speed (%.1fx Slow-Mo)", speedPercentage, slowMultiplier))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.brandAccent)
                    }

                    Spacer()

                    let clipDurationSec = Double(max(100, outPointMs - inPointMs)) / 1000.0
                    let outputDurationSec = clipDurationSec * (100.0 / speedPercentage)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Output Duration")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.textMuted)
                        Text(String(format: "%.1fs", outputDurationSec))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.emeraldAccent)
                    }
                }

                // Preset Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(speedPresets, id: \.pct) { preset in
                            Button(action: {
                                speedPercentage = preset.pct
                                playerModel.triggerHaptic()
                                updatePlayerRate()
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

                // Fine Continuous Slider (1% to 100%)
                VStack(spacing: 4) {
                    Slider(value: $speedPercentage, in: 1.0...100.0, step: 0.5) { _ in
                        updatePlayerRate()
                    }
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
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var interpolationCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("MOTION INTERPOLATION ENGINE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textTertiary)
                        .tracking(1.0)
                    Spacer()
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.brandAccent)
                        .font(.system(size: 12))
                }

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
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var audioAndFramerateCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // Target Framerate
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

                // Audio Retiming Mode
                VStack(alignment: .leading, spacing: 6) {
                    Text("AUDIO RETIMING")
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

    @ViewBuilder
    private func actionSection(info: VideoInfo) -> some View {
        VStack(spacing: 12) {
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

                        ProgressView(value: processProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .brandAccent))
                    }
                }
                .padding(.horizontal, 16)
            }

            // Export / Stop Action Button
            if isProcessing {
                Button(action: stopProcess) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text("Stop Slow-Mo Processing")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(hex: "FF453A"))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 16)
            } else {
                Button(action: generateSlowMotion) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                        Text(String(format: "Export Smooth Slow-Mo (%.0f%%)", speedPercentage))
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(LinearGradient.brandGradient)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 16)
            }

            // Share / Save to Files Button
            if let _ = exportedFileUrl {
                Button(action: { showShareSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .bold))
                        Text("Share / Save Slow-Mo Video")
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
        }
    }

    private var remuxModal: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
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

                    ProgressView(value: remuxProgress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle(tint: .brandAccent))

                    HStack {
                        Text(remuxSpeedText.isEmpty ? "Losslessly repackaging to MP4..." : "Stream Copying @ \(remuxSpeedText)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.emeraldAccent)

                        Spacer()

                        Text("0% Quality Loss")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.textMuted)
                    }

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

    // MARK: - Logic & Actions

    private func togglePlayPause() {
        if playerModel.isPlaying {
            playerModel.pause()
        } else {
            updatePlayerRate()
            playerModel.play()
        }
    }

    private func updatePlayerRate() {
        // Preview rate in AVPlayer
        let rate = Float(max(0.1, speedPercentage / 100.0))
        if playerModel.isPlaying {
            playerModel.player.rate = rate
        }
    }

    private func stopProcess() {
        SlowMoEngine.shared.cancel()
        playerModel.triggerHaptic()
        isProcessing = false
        processProgress = 0.0
    }

    private func generateSlowMotion() {
        guard let url = videoUrl, !isProcessing else { return }
        isProcessing = true
        processProgress = 0.0
        processSpeedText = "Initializing..."

        let info = videoInfo

        Task {
            let result = await SlowMoEngine.shared.createSlowMotion(
                sourceUrl: url,
                speedPercentage: speedPercentage,
                targetFps: targetFps,
                interpolationMode: selectedInterpolation,
                audioMode: selectedAudioMode,
                inPointMs: inPointMs,
                outPointMs: outPointMs,
                totalSourceDurationMs: info?.durationMs ?? 0,
                onProgress: { p, speed in
                    self.processProgress = p
                    self.processSpeedText = speed
                }
            )

            await MainActor.run {
                self.isProcessing = false
                if result.errorMessage == "OPERATION_CANCELLED" {
                    return
                }
                if result.success, let outUrl = result.outputUrl {
                    self.exportedFileUrl = outUrl
                    if result.errorMessage != nil {
                        self.showShareSheet = true
                    } else {
                        self.alertMessage = "✓ Smooth slow-mo video exported and saved to Camera Roll!"
                        self.showAlert = true
                    }
                } else {
                    self.alertMessage = "Slow-Mo Error: \(result.errorMessage ?? "Unknown error")"
                    self.showAlert = true
                }
            }
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
                    self.playerModel.setup(with: url)
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
                    self.playerModel.setup(with: workingUrl)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = "Failed to load video: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}
