import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Frame Sequence View
struct FrameSequenceView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var playerModel = PlayerModel()

    @State private var selectedPhotosItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false
    @State private var videoUrl: URL? = nil

    @State private var startMs: Int64 = 0
    @State private var endMs: Int64 = 0
    @State private var totalDurationMs: Int64 = 0
    @State private var sourceFps: Double = 30.0

    @State private var selectedFormat: SequenceFormat = .png
    @State private var selectedFps: SequenceFPS = .source
    @State private var selectedDestination: SequenceDestination = .photosAlbum

    // Extraction State
    @State private var isExtracting: Bool = false
    @State private var extractProgress: Float = 0.0
    @State private var extractedFrameCounter: Int = 0
    @State private var exportResult: SequenceExportResult? = nil
    @State private var showShareSheet: Bool = false
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                navigationHeader

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if let _ = videoUrl {
                            // 1. Live Video Player Preview
                            videoPlayerCard

                            // 2. Sequence Estimate & Auto-FPS Badge
                            sequenceEstimateCard

                            // 3. Time Range & In/Out Setters
                            timeRangeCard

                            // 4. Destination Selector (Photos Album Default)
                            destinationSelectorCard

                            // 5. Format Card (PNG / JPEG / TIFF)
                            formatSelectorCard

                            // 6. FPS Selector (Defaults to Native Source)
                            fpsSelectorCard

                            // 7. Export Action Button
                            exportActionButton

                            // 8. Progress Card
                            if isExtracting {
                                progressCard
                            }

                            // 9. Success Card
                            if let result = exportResult, result.success {
                                successResultCard(result: result)
                            }
                        } else {
                            // Empty State
                            importOptionsSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationBarHidden(true)
        .photosPicker(
            isPresented: .init(
                get: { selectedPhotosItem != nil },
                set: { if !$0 { selectedPhotosItem = nil } }
            ),
            selection: $selectedPhotosItem,
            matching: .videos
        )
        .onChange(of: selectedPhotosItem) { newItem in
            handlePhotosItem(newItem)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.movie, UTType.video, UTType.quickTimeMovie, UTType.mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    loadVideoUrl(url)
                }
            case .failure(let error):
                alertMessage = "File import error: \(error.localizedDescription)"
                showAlert = true
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let outUrl = exportResult?.outputUrl {
                SequenceShareSheet(activityItems: [outUrl])
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("Sequence Exporter"),
                message: Text(alertMessage ?? "An unknown error occurred."),
                dismissButton: .default(Text("OK"))
            )
        }
        .onDisappear {
            playerModel.cleanup()
        }
    }

    // MARK: - Navigation Header
    private var navigationHeader: some View {
        HStack(alignment: .center) {
            Button(action: {
                playerModel.cleanup()
                dismiss()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Color.elevatedSurface)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.borderHairline, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("SEQUENCE EXPORTER")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(String(format: "%.1f FPS", sourceFps))
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundColor(.emeraldAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.emeraldAccent.opacity(0.14))
                        .clipShape(Capsule())
                }

                Text("Auto-FPS Frame Sequence ➔ Dedicated Photos Album")
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            if videoUrl != nil {
                Button(action: { reset() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 38, height: 38)
                        .background(Color.elevatedSurface)
                        .clipShape(Circle())
                        .overlay(
                            Circle().stroke(Color.borderHairline, lineWidth: 1)
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Video Player Card
    private var videoPlayerCard: some View {
        GlassCard(cornerRadius: 18, padding: 12) {
            VStack(spacing: 10) {
                // Video Screen
                ZStack {
                    VideoPlayerView(player: playerModel.player)
                        .frame(height: 200)
                        .cornerRadius(12)
                        .clipped()

                    // Play / Pause Overlay
                    VStack {
                        Spacer()
                        HStack {
                            Button(action: {
                                if playerModel.isPlaying {
                                    playerModel.pause()
                                } else {
                                    playerModel.play()
                                }
                            }) {
                                Image(systemName: playerModel.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 38, height: 38)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())
                            }

                            Spacer()

                            // Frame Stepper Buttons
                            HStack(spacing: 6) {
                                Button(action: { stepFrame(forward: false) }) {
                                    Text("-1 Frame")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(Capsule())
                                }

                                Button(action: { stepFrame(forward: true) }) {
                                    Text("+1 Frame")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                // Timecode & IN/OUT Setters
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CURRENT PLAYHEAD")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundColor(.textTertiary)
                        Text(formatMs(playerModel.currentPositionMs))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.skyAccent)
                    }

                    Spacer()

                    // Quick Set IN
                    Button(action: {
                        startMs = playerModel.currentPositionMs
                        if endMs <= startMs {
                            endMs = min(totalDurationMs, startMs + 1000)
                        }
                    }) {
                        Text("Set [IN]")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.brandAccent.opacity(0.14))
                            .clipShape(Capsule())
                    }

                    // Quick Set OUT
                    Button(action: {
                        endMs = max(startMs + 100, playerModel.currentPositionMs)
                    }) {
                        Text("Set [OUT]")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.skyAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.skyAccent.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Sequence Estimate Card
    private var sequenceEstimateCard: some View {
        let durationSec = max(0.05, Double(endMs - startMs) / 1000.0)
        let effectiveFps = selectedFps.numericValue ?? sourceFps
        let estimatedFrames = max(1, Int(durationSec * effectiveFps))

        return GlassCard(cornerRadius: 18, padding: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.emeraldAccent.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.emeraldAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(estimatedFrames) Frames")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Text("AUTO-FPS")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundColor(.emeraldAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.emeraldAccent.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    Text(String(format: "%.2fs segment at %.1f FPS (%@)", durationSec, effectiveFps, selectedFormat.fileExtension.uppercased()))
                        .font(.system(size: 11.5))
                        .foregroundColor(.emeraldAccent)
                }

                Spacer()
            }
        }
    }

    // MARK: - Time Range Card
    private var timeRangeCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("SEQUENCE TIME RANGE")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(.skyAccent)
                        .tracking(0.8)

                    Spacer()

                    // Quick duration chips
                    HStack(spacing: 6) {
                        quickRangeChip(label: "1s", durationMs: 1000)
                        quickRangeChip(label: "2s", durationMs: 2000)
                        quickRangeChip(label: "Full", durationMs: totalDurationMs)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IN POINT")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.textTertiary)
                        Text(formatMs(startMs))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.brandAccent)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("OUT POINT")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.textTertiary)
                        Text(formatMs(endMs))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.skyAccent)
                    }
                }

                // Range Sliders
                Slider(
                    value: Binding<Double>(
                        get: { Double(startMs) },
                        set: {
                            startMs = min(Int64($0), endMs - 100)
                            playerModel.seek(to: startMs)
                        }
                    ),
                    in: 0...Double(max(500, totalDurationMs))
                )
                .tint(Color.brandAccent)

                Slider(
                    value: Binding<Double>(
                        get: { Double(endMs) },
                        set: {
                            endMs = max(Int64($0), startMs + 100)
                            playerModel.seek(to: endMs)
                        }
                    ),
                    in: 0...Double(max(500, totalDurationMs))
                )
                .tint(Color.skyAccent)
            }
        }
    }

    private func quickRangeChip(label: String, durationMs: Int64) -> some View {
        Button(action: {
            if durationMs >= totalDurationMs {
                startMs = 0
                endMs = totalDurationMs
            } else {
                endMs = min(totalDurationMs, startMs + durationMs)
            }
            playerModel.seek(to: startMs)
        }) {
            Text(label)
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundColor(.skyAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.skyAccent.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    // MARK: - Destination Selector Card
    private var destinationSelectorCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SAVE DESTINATION")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(.skyAccent)
                        .tracking(0.8)

                    Spacer()

                    Text("NO CONFUSION")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(.emeraldAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.emeraldAccent.opacity(0.2))
                        .clipShape(Capsule())
                }

                VStack(spacing: 8) {
                    ForEach(SequenceDestination.allCases) { dest in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedDestination = dest
                            }
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: selectedDestination == dest ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(selectedDestination == dest ? .emeraldAccent : .textTertiary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dest.rawValue)
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundColor(selectedDestination == dest ? .textPrimary : .textSecondary)

                                    if dest == .photosAlbum, let url = videoUrl {
                                        Text("Creates album: 'CFX Sequence - \(url.deletingPathExtension().lastPathComponent)'")
                                            .font(.system(size: 10))
                                            .foregroundColor(.emeraldAccent)
                                    }
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(selectedDestination == dest ? Color.elevatedSurface : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selectedDestination == dest ? Color.emeraldAccent.opacity(0.5) : Color.borderHairline, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Format Selector Card
    private var formatSelectorCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("IMAGE FORMAT")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundColor(.skyAccent)
                    .tracking(0.8)

                HStack(spacing: 8) {
                    ForEach(SequenceFormat.allCases) { fmt in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedFormat = fmt
                            }
                        }) {
                            VStack(spacing: 3) {
                                Text(fmt.fileExtension.uppercased())
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(selectedFormat == fmt ? .white : .textPrimary)
                                Text(fmt == .png ? "Lossless" : (fmt == .jpeg ? "Compact" : "Master"))
                                    .font(.system(size: 9))
                                    .foregroundColor(selectedFormat == fmt ? .white.opacity(0.8) : .textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(selectedFormat == fmt ? Color.brandAccent : Color.elevatedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selectedFormat == fmt ? Color.brandAccent : Color.borderHairline, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - FPS Selector Card
    private var fpsSelectorCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("FRAME RATE (FPS)")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(.skyAccent)
                        .tracking(0.8)

                    Spacer()

                    Text(String(format: "Source: %.1f FPS", sourceFps))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.emeraldAccent)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SequenceFPS.allCases) { fps in
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedFps = fps
                                }
                            }) {
                                Text(fps == .source ? String(format: "Native (%.1f FPS)", sourceFps) : fps.rawValue)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(selectedFps == fps ? .white : .textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(selectedFps == fps ? Color.skyAccent : Color.elevatedSurface)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule().stroke(Color.borderHairline, lineWidth: 1)
                                    )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Export Action Button
    private var exportActionButton: some View {
        Button(action: { startExtraction() }) {
            HStack(spacing: 10) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 16, weight: .bold))

                Text("Export Sequence Now")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.emeraldAccent, Color(hex: "00B4DB")],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.emeraldAccent.opacity(0.35), radius: 10, y: 4)
        }
        .disabled(isExtracting)
    }

    // MARK: - Progress Card
    private var progressCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(spacing: 8) {
                HStack {
                    Text("EXTRACTING FRAMES...")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.emeraldAccent)
                    Spacer()
                    Text("Frame \(extractedFrameCounter)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                }

                ProgressView(value: extractProgress, total: 1.0)
                    .tint(Color.emeraldAccent)
            }
        }
    }

    // MARK: - Success Result Card
    private func successResultCard(result: SequenceExportResult) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.emeraldAccent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(result.frameCount) Frames Exported!")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.textPrimary)

                        if let album = result.destinationAlbumTitle {
                            Text("Saved to Photos Album: '\(album)'")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.emeraldAccent)
                        } else {
                            Text("Size: \(ByteCountFormatter.string(fromByteCount: result.totalSizeBytes, countStyle: .file))")
                                .font(.system(size: 11))
                                .foregroundColor(.textMuted)
                        }
                    }

                    Spacer()
                }

                Divider().background(Color.borderHairline)

                if selectedDestination == .photosAlbum {
                    Button(action: {
                        if let url = URL(string: "photos-redirect://") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 13, weight: .bold))
                            Text("Open Photos App ➔ View Album")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.emeraldAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                } else {
                    Button(action: { showShareSheet = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("Save to Files / AirDrop")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.skyAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - Import Options Section
    private var importOptionsSection: some View {
        VStack(spacing: 16) {
            Button(action: { selectedPhotosItem = nil }) {
                PhotosPicker(selection: $selectedPhotosItem, matching: .videos) {
                    GlassCard(cornerRadius: 18, padding: 20) {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.emeraldAccent.opacity(0.14))
                                    .frame(width: 48, height: 48)

                                Image(systemName: "photo.stack")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.emeraldAccent)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Import from Camera Roll")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.textPrimary)

                                Text("High-frame-rate videos & clips")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.textMuted)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.textTertiary)
                        }
                    }
                }
            }

            Button(action: { showFilePicker = true }) {
                GlassCard(cornerRadius: 18, padding: 20) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.brandAccent.opacity(0.14))
                                .frame(width: 48, height: 48)

                            Image(systemName: "folder.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.brandAccent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Import from Files App")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.textPrimary)

                            Text("Render clips, ProRes & external media")
                                .font(.system(size: 11.5))
                                .foregroundColor(.textMuted)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textTertiary)
                    }
                }
            }

            GlassCard(cornerRadius: 16, padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.emeraldAccent)
                        Text("DEDICATED ALBUM EXPORT")
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundColor(.emeraldAccent)
                    }

                    Text("• Automatically saves all exported frames into a named album inside Photos so your camera roll stays organized.\n• Video player allows setting [IN] and [OUT] points frame-accurately.\n• Auto-matches your video's native FPS (24, 30, 60 FPS) with 0% jitter.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.textSecondary)
                        .lineSpacing(4)
                }
            }
        }
    }

    // MARK: - Handlers
    private func handlePhotosItem(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            if let movie = try? await item.loadTransferable(type: MovieTransferable.self) {
                await MainActor.run {
                    loadVideoUrl(movie.url)
                }
            }
        }
    }

    private func loadVideoUrl(_ url: URL) {
        self.videoUrl = url
        self.exportResult = nil

        let asset = AVURLAsset(url: url)
        Task {
            let duration = (try? await asset.load(.duration)) ?? .zero
            let durationSec = CMTimeGetSeconds(duration)
            let durMs = Int64(durationSec * 1000)

            var fps = 30.0
            if let videoTracks = try? await asset.loadTracks(withMediaType: .video), let vTrack = videoTracks.first {
                if let nominalRate = try? await vTrack.load(.nominalFrameRate), nominalRate > 0 {
                    fps = Double(nominalRate)
                }
            }

            await MainActor.run {
                self.sourceFps = fps
                self.selectedFps = .source // Auto-match native FPS by default
                self.totalDurationMs = durMs
                self.startMs = 0
                // Default to first 1.5 seconds for quick preview
                self.endMs = min(durMs, 1500)

                // Setup video player
                self.playerModel.setup(with: url)
            }
        }
    }

    private func stepFrame(forward: Bool) {
        let frameDurationSec = 1.0 / max(1.0, sourceFps)
        let currentSec = CMTimeGetSeconds(playerModel.player.currentTime())
        let nextSec = forward ? (currentSec + frameDurationSec) : max(0.0, currentSec - frameDurationSec)
        let targetMs = Int64(nextSec * 1000.0)
        playerModel.seek(to: targetMs)
    }

    private func startExtraction() {
        guard let url = videoUrl else { return }
        isExtracting = true
        extractProgress = 0.0
        extractedFrameCounter = 0

        playerModel.pause()

        Task {
            let result = await FrameSequenceEngine.shared.exportSequence(
                srcUrl: url,
                startMs: startMs,
                endMs: endMs,
                fpsMode: selectedFps,
                format: selectedFormat,
                destination: selectedDestination
            ) { progress, currentFrame in
                self.extractProgress = progress
                self.extractedFrameCounter = currentFrame
            }

            await MainActor.run {
                self.isExtracting = false
                if result.success {
                    self.exportResult = result
                } else {
                    self.alertMessage = result.errorMessage ?? "Sequence extraction failed"
                    self.showAlert = true
                }
            }
        }
    }

    private func reset() {
        playerModel.cleanup()
        videoUrl = nil
        exportResult = nil
        isExtracting = false
    }

    private func formatMs(_ ms: Int64) -> String {
        let totalSeconds = Double(ms) / 1000.0
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let millis = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, millis)
    }
}

// MARK: - Sequence Share Sheet
struct SequenceShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
