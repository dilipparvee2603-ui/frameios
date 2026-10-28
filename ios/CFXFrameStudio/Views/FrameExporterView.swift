import SwiftUI
import AVFoundation
import PhotosUI

struct FrameExporterView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var videoUrl: URL? = nil
    @State private var videoInfo: VideoInfo? = nil

    @State private var player: AVPlayer = AVPlayer()
    @State private var isPlaying: Bool = false
    @State private var isMuted: Bool = false
    @State private var currentPositionMs: Int64 = 0

    @State private var previewImage: UIImage? = nil
    @State private var selectedFormat: FrameFormat = .png
    @State private var isExporting: Bool = false

    @State private var showTimecodeModal: Bool = false
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    @State private var timeObserverToken: Any? = nil

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Header Bar
                    HStack {
                        Button(action: {
                            cleanupPlayer()
                            dismiss()
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.textPrimary)
                                .frame(width: 36, height: 36)
                                .background(Color.surfaceCard)
                                .clipShape(Circle())
                        }

                        Text("FRAME EXPORTER STUDIO")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Spacer()

                        PhotosPicker(selection: $selectedItem, matching: .videos) {
                            Image(systemName: "video.badge.plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.skyAccent)
                                .frame(width: 36, height: 36)
                                .background(Color.surfaceCard)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    if videoUrl == nil {
                        // Empty State
                        PhotosPicker(selection: $selectedItem, matching: .videos) {
                            GlassCard(cornerRadius: 18, padding: 32) {
                                VStack(spacing: 14) {
                                    Image(systemName: "photo.stack")
                                        .font(.system(size: 44, weight: .semibold))
                                        .foregroundColor(.skyAccent)

                                    Text("Select Video for Frame Extraction")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.textPrimary)

                                    Text("Step by 1 frame or 10 frames\nExport exact uncompressed PNG & JPG")
                                        .font(.system(size: 12))
                                        .foregroundColor(.textMuted)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 40)
                    } else {
                        // Video Player Card with Exact Frame Overlay
                        ZStack(alignment: .topLeading) {
                            VideoPlayerView(player: player)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.borderHairline, lineWidth: 1)
                                )

                            // Exact Uncompressed Frame Overlay when paused
                            if !isPlaying, let img = previewImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }

                            // Floating Mute Button (Top-Left)
                            Button(action: toggleMute) {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(isMuted ? Color(hex: "FF5252") : .white)
                                    .frame(width: 34, height: 34)
                                    .background(Color.black.opacity(0.75))
                                    .clipShape(Circle())
                            }
                            .padding(10)

                            // Resolution & FPS Badge (Top-Right)
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

                        // Stepping & Transport Card
                        if let info = videoInfo {
                            GlassCard(cornerRadius: 16, padding: 14) {
                                VStack(spacing: 14) {
                                    // Timecode & Frame Counter Header
                                    HStack {
                                        Button(action: { showTimecodeModal = true }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "clock")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.skyAccent)
                                                Text(formatMsToTimecode(currentPositionMs))
                                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.textPrimary)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.elevatedSurface)
                                            .cornerRadius(6)
                                        }

                                        Spacer()

                                        let currentFrame = Int64((Double(currentPositionMs) / 1000.0) * info.fps)
                                        Text("Frame \(currentFrame) / \(info.totalFrames)")
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.textMuted)
                                    }

                                    // Timeline Scrubber
                                    GeometryReader { geo in
                                        let width = geo.size.width
                                        let duration = max(1, Double(info.durationMs))
                                        let playheadFraction = CGFloat(Double(currentPositionMs) / duration)

                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.elevatedSurface)
                                                .frame(height: 6)

                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.skyAccent)
                                                .frame(width: max(2, playheadFraction * width), height: 6)

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
                                                    seek(to: targetMs)
                                                }
                                        )
                                    }
                                    .frame(height: 18)

                                    // 1f & 10f Frame Stepping Controls
                                    HStack(spacing: 8) {
                                        stepButton("-10f") { stepFrames(-10) }
                                        stepButton("-1f") { stepFrames(-1) }

                                        Button(action: togglePlayPause) {
                                            ZStack {
                                                Circle()
                                                    .fill(LinearGradient.brandGradient)
                                                    .frame(width: 46, height: 46)
                                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(.white)
                                            }
                                        }

                                        stepButton("+1f") { stepFrames(1) }
                                        stepButton("+10f") { stepFrames(10) }

                                        Button(action: toggleMute) {
                                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(isMuted ? Color(hex: "FF5252") : .textMuted)
                                                .frame(width: 36, height: 36)
                                                .background(Color.elevatedSurface)
                                                .clipShape(Circle())
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)

                            // Format Picker (PNG / JPG)
                            GlassCard(cornerRadius: 14, padding: 12) {
                                HStack {
                                    Text("Image Format")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.textPrimary)

                                    Spacer()

                                    HStack(spacing: 6) {
                                        formatPill("PNG (Lossless)", isSelected: selectedFormat == .png) {
                                            selectedFormat = .png
                                        }
                                        formatPill("JPG (95%)", isSelected: selectedFormat == .jpg) {
                                            selectedFormat = .jpg
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)

                            // Export Frame Button
                            Button(action: exportCurrentFrame) {
                                HStack(spacing: 8) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(isExporting ? "Exporting Frame..." : "Export Current Frame (\(selectedFormat.rawValue))")
                                        .font(.system(size: 14, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(LinearGradient.brandGradient)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(isExporting)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }

            // Timecode Jump Modal
            if showTimecodeModal, let info = videoInfo {
                TimecodeEntryModal(
                    target: .playhead,
                    initialMs: currentPositionMs,
                    durationMs: info.durationMs,
                    onApply: { newMs in
                        seek(to: newMs)
                    },
                    onDismiss: { showTimecodeModal = false }
                )
            }
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let item = newItem {
                    await loadVideo(from: item)
                }
            }
        }
        .alert(alertMessage ?? "", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    private func stepButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.elevatedSurface)
                .cornerRadius(8)
        }
    }

    private func formatPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isSelected ? .white : .textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.brandAccent : Color.elevatedSurface)
                .cornerRadius(6)
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
                    self.currentPositionMs = 0
                    setupPlayer(with: url)
                }
            }
        } catch {
            await MainActor.run {
                self.alertMessage = "Failed to load video: \(error.localizedDescription)"
                self.showAlert = true
            }
        }
    }

    private func setupPlayer(with url: URL) {
        cleanupPlayer()
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player.isMuted = isMuted

        let interval = CMTime(value: 1, timescale: 30)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            let ms = Int64(CMTimeGetSeconds(time) * 1000)
            self.currentPositionMs = ms
        }
    }

    private func cleanupPlayer() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player.pause()
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
            updateExactFramePreview()
        } else {
            previewImage = nil
            player.play()
            isPlaying = true
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    private func seek(to ms: Int64) {
        currentPositionMs = ms
        let cmTime = CMTime(value: CMTimeValue(ms), timescale: 1000)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        if !isPlaying {
            updateExactFramePreview()
        }
    }

    private func stepFrames(_ delta: Int64) {
        guard let info = videoInfo else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        let frameDurationMs = max(1.0, 1000.0 / info.fps)
        let targetMs = max(0, min(info.durationMs, currentPositionMs + Int64(Double(delta) * frameDurationMs)))
        seek(to: targetMs)
    }

    private func updateExactFramePreview() {
        guard let url = videoUrl else { return }
        let ms = currentPositionMs
        Task {
            if let frame = try? await VideoEngine.shared.extractFrame(from: url, at: ms) {
                await MainActor.run {
                    self.previewImage = frame
                }
            }
        }
    }

    private func exportCurrentFrame() {
        guard let url = videoUrl, !isExporting else { return }
        isExporting = true

        Task {
            do {
                let frame = try await VideoEngine.shared.extractFrame(from: url, at: currentPositionMs)
                let saved = try await VideoEngine.shared.saveFrameToPhotos(image: frame, format: selectedFormat)
                await MainActor.run {
                    self.isExporting = false
                    if saved {
                        self.alertMessage = "✓ Frame exported and saved to Camera Roll!"
                    } else {
                        self.alertMessage = "Failed to save image to Photos"
                    }
                    self.showAlert = true
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.alertMessage = "Export Error: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}
