import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Frame Sequence View
struct FrameSequenceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhotosItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false
    @State private var videoUrl: URL? = nil

    @State private var startMs: Int64 = 0
    @State private var endMs: Int64 = 0
    @State private var totalDurationMs: Int64 = 0
    @State private var sourceFps: Double = 30.0

    @State private var selectedFormat: SequenceFormat = .png
    @State private var selectedFps: SequenceFPS = .source
    @State private var selectedDestination: SequenceDestination = .zipArchive

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
                            // Sequence Estimate Card
                            sequenceEstimateCard

                            // Time Range Selector Card
                            timeRangeCard

                            // Frame Rate Card
                            fpsSelectorCard

                            // Format Card
                            formatSelectorCard

                            // Destination Card
                            destinationSelectorCard

                            // Export Button
                            exportActionButton

                            // Progress Card
                            if isExtracting {
                                progressCard
                            }

                            // Success Card
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
    }

    // MARK: - Navigation Header
    private var navigationHeader: some View {
        HStack(alignment: .center) {
            Button(action: { dismiss() }) {
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

                    Text("VFX STUDIO")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundColor(.skyAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.skyAccent.opacity(0.14))
                        .clipShape(Capsule())
                }

                Text("Batch Export 60 FPS Numbered PNG Sequences")
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

    // MARK: - Import Options Section
    private var importOptionsSection: some View {
        VStack(spacing: 16) {
            // Camera Roll Button
            Button(action: { selectedPhotosItem = nil }) {
                PhotosPicker(selection: $selectedPhotosItem, matching: .videos) {
                    GlassCard(cornerRadius: 18, padding: 20) {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.skyAccent.opacity(0.14))
                                    .frame(width: 48, height: 48)

                                Image(systemName: "photo.stack")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.skyAccent)
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

            // Files App Button
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

            // VFX Use-Cases Card
            GlassCard(cornerRadius: 16, padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.emeraldAccent)
                        Text("VFX & EDITOR WORKFLOW")
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundColor(.emeraldAccent)
                    }

                    Text("• Dumps every microsecond frame as lossless uncompressed PNGs.\n• Automatically packages into a single .ZIP archive so your Camera Roll stays clean.\n• Ideal for 3D camera tracking, AI rotoscoping, anime edits, or picking the sharpest thumbnail.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.textSecondary)
                        .lineSpacing(4)
                }
            }
        }
    }

    // MARK: - Sequence Estimate Card
    private var sequenceEstimateCard: some View {
        let durationSec = max(0.1, Double(endMs - startMs) / 1000.0)
        let effectiveFps = selectedFps.numericValue ?? sourceFps
        let estimatedFrames = max(1, Int(durationSec * effectiveFps))

        return GlassCard(cornerRadius: 18, padding: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.skyAccent.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Image(systemName: "film")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.skyAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(estimatedFrames) Frames to Export")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(String(format: "%.2fs segment at %.0f FPS (%@)", durationSec, effectiveFps, selectedFormat.fileExtension.uppercased()))
                        .font(.system(size: 11.5))
                        .foregroundColor(.skyAccent)
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
                            .foregroundColor(.textPrimary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("OUT POINT")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.textTertiary)
                        Text(formatMs(endMs))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.textPrimary)
                    }
                }

                // Range Sliders
                Slider(
                    value: Binding<Double>(
                        get: { Double(startMs) },
                        set: { startMs = min(Int64($0), endMs - 200) }
                    ),
                    in: 0...Double(max(500, totalDurationMs))
                )
                .tint(Color.brandAccent)

                Slider(
                    value: Binding<Double>(
                        get: { Double(endMs) },
                        set: { endMs = max(Int64($0), startMs + 200) }
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

    // MARK: - FPS Selector Card
    private var fpsSelectorCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("FRAME RATE (FPS)")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundColor(.skyAccent)
                    .tracking(0.8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SequenceFPS.allCases) { fps in
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedFps = fps
                                }
                            }) {
                                Text(fps.rawValue)
                                    .font(.system(size: 11.5, weight: .bold))
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

    // MARK: - Destination Selector Card
    private var destinationSelectorCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("OUTPUT DESTINATION")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundColor(.skyAccent)
                    .tracking(0.8)

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

                                Text(dest.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(selectedDestination == dest ? .textPrimary : .textSecondary)

                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(selectedDestination == dest ? Color.elevatedSurface : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    colors: [Color.skyAccent, Color(hex: "0083B0")],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.skyAccent.opacity(0.35), radius: 10, y: 4)
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
                        .foregroundColor(.skyAccent)
                    Spacer()
                    Text("Frame \(extractedFrameCounter)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                }

                ProgressView(value: extractProgress, total: 1.0)
                    .tint(Color.skyAccent)
            }
        }
    }

    // MARK: - Success Result Card
    private func successResultCard(result: SequenceExportResult) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.emeraldAccent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(result.frameCount) Frames Exported!")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Text("Total size: \(ByteCountFormatter.string(fromByteCount: result.totalSizeBytes, countStyle: .file))")
                            .font(.system(size: 11))
                            .foregroundColor(.textMuted)
                    }

                    Spacer()
                }

                Divider().background(Color.borderHairline)

                Button(action: { showShareSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(selectedDestination == .zipArchive ? "Save ZIP to Files / AirDrop" : "Open in Files")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.emeraldAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                self.totalDurationMs = durMs
                self.startMs = 0
                // Default to first 2 seconds for ultra-fast preview
                self.endMs = min(durMs, 2000)
            }
        }
    }

    private func startExtraction() {
        guard let url = videoUrl else { return }
        isExtracting = true
        extractProgress = 0.0
        extractedFrameCounter = 0

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
        videoUrl = nil
        exportResult = nil
        isExtracting = false
    }

    private func formatMs(_ ms: Int64) -> String {
        let totalSeconds = Double(ms) / 1000.0
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let millis = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, millis)
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
