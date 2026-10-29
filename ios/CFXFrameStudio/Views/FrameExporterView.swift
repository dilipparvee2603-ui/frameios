import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct FrameExporterView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var playerModel = PlayerModel()

    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false
    @State private var videoUrl: URL? = nil
    @State private var videoInfo: VideoInfo? = nil

    @State private var selectedFormat: FrameFormat = .png
    @State private var isExporting: Bool = false
    @State private var exportedFileUrl: URL? = nil
    @State private var showShareSheet: Bool = false

    @State private var isRemuxing: Bool = false
    @State private var remuxProgress: Double = 0.0
    @State private var remuxSpeedText: String = ""
    @State private var showTimecodeModal: Bool = false
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

                        Text("FRAME EXPORTER STUDIO")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Spacer()

                        HStack(spacing: 8) {
                            PhotosPicker(selection: $selectedItem, matching: .videos) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.skyAccent)
                                    .frame(width: 36, height: 36)
                                    .background(Color.surfaceCard)
                                    .clipShape(Circle())
                            }

                            Button(action: { showFilePicker = true }) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.skyAccent)
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
                                                .fill(Color.skyAccent.opacity(0.15))
                                                .frame(width: 48, height: 48)
                                            Image(systemName: "photo.on.rectangle.angled")
                                                .font(.system(size: 22, weight: .bold))
                                                .foregroundColor(.skyAccent)
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Import from Camera Roll")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.textPrimary)
                                            Text("Photos library videos & recordings")
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
                                            Text("MP4, MOV, MKV, WebM from Downloads & Files")
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
                        // Video Player Card with Exact Frame Overlay
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
                                            HStack(spacing: 5) {
                                                Image(systemName: "clock.badge.checkmark")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.skyAccent)
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

                                        let currentFrame = playerModel.currentFrameIndex(fps: info.fps)
                                        let pct = min(100.0, max(0.0, (Double(currentFrame) / max(1.0, Double(info.totalFrames))) * 100.0))
                                        Text("Frame #\(currentFrame) / \(info.totalFrames) (\(String(format: "%.1f", pct))%)")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.textMuted)
                                    }

                                    // Timeline Scrubber
                                    GeometryReader { geo in
                                        let width = geo.size.width
                                        let duration = max(1, Double(info.durationMs))
                                        let playheadFraction = CGFloat(Double(playerModel.currentPositionMs) / duration)

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
                                                Image(systemName: playerModel.isPlaying ? "pause.fill" : "play.fill")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(.white)
                                            }
                                        }

                                        stepButton("+1f") { stepFrames(1) }
                                        stepButton("+10f") { stepFrames(10) }

                                        Button(action: { playerModel.toggleMute() }) {
                                            Image(systemName: playerModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(playerModel.isMuted ? Color(hex: "FF5252") : .textMuted)
                                                .frame(width: 36, height: 36)
                                                .background(Color.elevatedSurface)
                                                .clipShape(Circle())
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)

                            // Master Format Picker (PNG / JPG 100% / HEIC / TIFF)
                            GlassCard(cornerRadius: 14, padding: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Master Export Format")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.textPrimary)

                                        Spacer()

                                        Text(selectedFormat.rawValue)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.skyAccent)
                                    }

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(FrameFormat.allCases) { fmt in
                                                formatPill(fmt.rawValue, isSelected: selectedFormat == fmt) {
                                                    selectedFormat = fmt
                                                }
                                            }
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

                            // Share / Save Frame to Files Button
                            if let _ = exportedFileUrl {
                                Button(action: { showShareSheet = true }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.system(size: 15, weight: .bold))
                                        Text("Share / Save Frame to Files")
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

            // Timecode Jump Modal
            if showTimecodeModal, let info = videoInfo {
                TimecodeEntryModal(
                    target: .playhead,
                    initialMs: playerModel.currentPositionMs,
                    durationMs: info.durationMs,
                    fps: info.fps,
                    onApply: { newMs in
                        seek(to: newMs)
                    },
                    onDismiss: { showTimecodeModal = false }
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
                                    .foregroundColor(.skyAccent)

                                Text("Optimizing Video for iOS")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.textPrimary)

                                Spacer()

                                Text("\(Int(remuxProgress * 100))%")
                                    .font(.system(size: 22, weight: .black, design: .rounded))
                                    .foregroundColor(.skyAccent)
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.elevatedSurface)
                                        .frame(height: 8)

                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(LinearGradient(colors: [Color.skyAccent, Color.brandAccent], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(0, geo.size.width * CGFloat(remuxProgress)), height: 8)
                                        .animation(.linear(duration: 0.15), value: remuxProgress)
                                }
                            }
                            .frame(height: 8)

                            HStack {
                                Text(remuxSpeedText.isEmpty ? "Direct Stream Copying..." : remuxSpeedText)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.emeraldAccent)

                                Spacer()

                                Text("100% Original Quality")
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
                                    Text("Cancel Optimization")
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
            if let outUrl = exportedFileUrl {
                ShareActivityView(activityItems: [outUrl])
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
                    self.videoUrl = url
                    self.videoInfo = info
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

            let tempDir = FileManager.default.temporaryDirectory
            let stagedUrl = tempDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: stagedUrl)

            do {
                try FileManager.default.copyItem(at: url, to: stagedUrl)
            } catch {
                await MainActor.run {
                    self.alertMessage = "Failed to access file: \(error.localizedDescription)"
                    self.showAlert = true
                }
                return
            }

            var workingUrl = stagedUrl

            if await MKVRemuxEngine.shared.requiresRemuxing(url: stagedUrl) {
                await MainActor.run {
                    self.isRemuxing = true
                    self.remuxProgress = 0.0
                    self.remuxSpeedText = "Direct Stream Copy..."
                }
                do {
                    workingUrl = try await MKVRemuxEngine.shared.remuxToMP4(sourceUrl: stagedUrl) { progress, speed in
                        Task { @MainActor in
                            self.remuxProgress = progress
                            self.remuxSpeedText = speed
                        }
                    }
                    try? FileManager.default.removeItem(at: stagedUrl)
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

            do {
                let info = try await VideoEngine.shared.extractVideoInfo(from: workingUrl)
                await MainActor.run {
                    self.videoUrl = workingUrl
                    self.videoInfo = info
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

    private func togglePlayPause() {
        if playerModel.isPlaying {
            playerModel.pause()
        } else {
            playerModel.play()
        }
    }

    private func seek(to ms: Int64) {
        playerModel.seek(to: ms)
    }

    private func stepFrames(_ delta: Int64) {
        guard let info = videoInfo else { return }
        playerModel.step(byCount: Int(delta), fps: info.fps, durationMs: info.durationMs)
    }

    private func exportCurrentFrame() {
        guard let url = videoUrl, !isExporting else { return }
        isExporting = true

        let currentCm = playerModel.currentPositionTime
        let currentMs = playerModel.currentPositionMs

        Task {
            do {
                // High-precision CMTime extraction eliminating fractional-millisecond drift
                let frame: UIImage
                if currentCm != .zero {
                    frame = try await VideoEngine.shared.extractFrame(from: url, at: currentCm)
                } else {
                    frame = try await VideoEngine.shared.extractFrame(from: url, at: currentMs)
                }

                let tempFile = try VideoEngine.shared.saveFrameToTempFile(image: frame, format: selectedFormat)

                var savedToPhotos = false
                do {
                    savedToPhotos = try await VideoEngine.shared.saveFrameToPhotos(image: frame, format: selectedFormat)
                } catch {
                    // Photos rejected format or permission issue (e.g. PHPhotosErrorDomain)
                    savedToPhotos = false
                }

                await MainActor.run {
                    self.isExporting = false
                    self.exportedFileUrl = tempFile
                    if savedToPhotos {
                        self.alertMessage = "✓ Master frame (\(self.selectedFormat.rawValue)) saved to Photos!"
                        self.showAlert = true
                    } else {
                        // Automatically open Save to Files / Share Sheet!
                        self.showShareSheet = true
                    }
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
