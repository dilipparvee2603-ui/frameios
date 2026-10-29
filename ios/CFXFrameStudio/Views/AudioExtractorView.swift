import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Audio Extractor View
struct AudioExtractorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhotosItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false
    @State private var videoUrl: URL? = nil
    @State private var trackInfo: AudioTrackInfo? = nil

    @State private var selectedFormat: AudioExportFormat = .m4a
    @State private var trimRangeEnabled: Bool = false
    @State private var startMs: Int64 = 0
    @State private var endMs: Int64 = 0
    @State private var totalDurationMs: Int64 = 0

    // Playback
    @State private var avPlayer: AVPlayer? = nil
    @State private var isPlaying: Bool = false
    @State private var currentTimeSec: Double = 0.0

    // Extraction State
    @State private var isExtracting: Bool = false
    @State private var extractProgress: Float = 0.0
    @State private var extractedResult: AudioExtractResult? = nil
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
                            // Active Video Audio Card
                            audioTrackMetaCard

                            // Playback Preview Card
                            audioPreviewCard

                            // Range Trimming Toggle & Card
                            rangeTrimCard

                            // Format Selector Card
                            formatSelectorCard

                            // Extract Action Button
                            extractActionButton

                            // Progress Card
                            if isExtracting {
                                progressCard
                            }

                            // Success Card
                            if let result = extractedResult, let outUrl = result.outputUrl {
                                successResultCard(outputUrl: outUrl)
                            }
                        } else {
                            // Empty State: Import Options
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
            if let outUrl = extractedResult?.outputUrl {
                AudioShareSheet(activityItems: [outUrl])
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("Audio Extractor"),
                message: Text(alertMessage ?? "An unknown error occurred."),
                dismissButton: .default(Text("OK"))
            )
        }
        .onDisappear {
            avPlayer?.pause()
            avPlayer = nil
        }
    }

    // MARK: - Navigation Header
    private var navigationHeader: some View {
        HStack(alignment: .center) {
            Button(action: {
                avPlayer?.pause()
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
                    Text("AUDIO EXTRACTOR")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text("0% LOSS")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundColor(.brandAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.brandAccent.opacity(0.14))
                        .clipShape(Capsule())
                }

                Text("Rip Clean Music, Dialogue & Voiceover from Videos")
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
                                    .fill(Color.brandAccent.opacity(0.14))
                                    .frame(width: 48, height: 48)

                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.brandAccent)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Import from Camera Roll")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.textPrimary)

                                Text("Videos, screen recordings & saved clips")
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
                                .fill(Color.skyAccent.opacity(0.14))
                                .frame(width: 48, height: 48)

                            Image(systemName: "folder.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.skyAccent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Import from Files App")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.textPrimary)

                            Text("iCloud Drive, MKVs, downloads & external storage")
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

            // Explainer Card
            GlassCard(cornerRadius: 16, padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.amberAccent)
                        Text("KEY HIGHLIGHTS")
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundColor(.amberAccent)
                    }

                    Text("• Rips audio via stream copy in 0.5s with zero compression loss.\n• Exports directly to M4A, 320 kbps MP3, 24-bit WAV, or Apple Lossless.\n• Perfect for adding dialogue, soundbites, or songs into CapCut & VN.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.textSecondary)
                        .lineSpacing(4)
                }
            }
        }
    }

    // MARK: - Audio Track Metadata Card
    private var audioTrackMetaCard: some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("AUDIO STREAM DETAILS")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(.skyAccent)
                        .tracking(0.8)

                    Spacer()

                    if let name = videoUrl?.lastPathComponent {
                        Text(name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.textTertiary)
                            .lineLimit(1)
                            .frame(maxWidth: 160, alignment: .trailing)
                    }
                }

                if let info = trackInfo {
                    HStack(spacing: 0) {
                        statCell(title: "CODEC", value: info.codecName, icon: "waveform")
                        Divider().frame(height: 30).background(Color.borderHairline)
                        statCell(title: "CHANNELS", value: info.channelsFormatted, icon: "speaker.wave.2")
                        Divider().frame(height: 30).background(Color.borderHairline)
                        statCell(title: "SAMPLE RATE", value: info.sampleRateFormatted, icon: "tuningfork")
                        Divider().frame(height: 30).background(Color.borderHairline)
                        statCell(title: "DURATION", value: formatMs(totalDurationMs), icon: "clock")
                    }
                } else {
                    ProgressView().tint(Color.brandAccent)
                }
            }
        }
    }

    private func statCell(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundColor(.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Audio Preview Card
    private var audioPreviewCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            HStack(spacing: 14) {
                Button(action: { togglePlayback() }) {
                    ZStack {
                        Circle()
                            .fill(Color.brandAccent)
                            .frame(width: 44, height: 44)

                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isPlaying ? "Playing Audio Stream" : "Audio Preview Ready")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textPrimary)

                    HStack(spacing: 6) {
                        Text(formatMs(Int64(currentTimeSec * 1000)))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.skyAccent)
                        Text("/")
                            .foregroundColor(.textTertiary)
                        Text(formatMs(totalDurationMs))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.textTertiary)
                    }
                }

                Spacer()

                // Waveform bars animation
                HStack(spacing: 3) {
                    ForEach(0..<6) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isPlaying ? Color.brandAccent : Color.textTertiary.opacity(0.3))
                            .frame(width: 3, height: isPlaying ? CGFloat([14, 24, 18, 28, 12, 20][i]) : 8)
                            .animation(isPlaying ? Animation.easeInOut(duration: 0.3).repeatForever().delay(Double(i) * 0.05) : .default, value: isPlaying)
                    }
                }
            }
        }
    }

    // MARK: - Range Trimming Card
    private var rangeTrimCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $trimRangeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Extract Specific Audio Segment")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.textPrimary)
                        Text("Only rip a specific chorus, dialogue, or soundbite")
                            .font(.system(size: 10.5))
                            .foregroundColor(.textMuted)
                    }
                }
                .tint(Color.brandAccent)

                if trimRangeEnabled {
                    Divider().background(Color.borderHairline)

                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("START TIME")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(.textTertiary)
                                Text(formatMs(startMs))
                                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(.textPrimary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("END TIME")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(.textTertiary)
                                Text(formatMs(endMs))
                                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(.textPrimary)
                            }
                        }

                        // Range Slider
                        Slider(
                            value: Binding<Double>(
                                get: { Double(startMs) },
                                set: { startMs = min(Int64($0), endMs - 500) }
                            ),
                            in: 0...Double(max(1000, totalDurationMs))
                        )
                        .tint(Color.brandAccent)

                        Slider(
                            value: Binding<Double>(
                                get: { Double(endMs) },
                                set: { endMs = max(Int64($0), startMs + 500) }
                            ),
                            in: 0...Double(max(1000, totalDurationMs))
                        )
                        .tint(Color.skyAccent)
                    }
                }
            }
        }
    }

    // MARK: - Format Selector Card
    private var formatSelectorCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("EXPORT AUDIO FORMAT")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundColor(.skyAccent)
                    .tracking(0.8)

                VStack(spacing: 8) {
                    ForEach(AudioExportFormat.allCases) { fmt in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedFormat = fmt
                            }
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: selectedFormat == fmt ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(selectedFormat == fmt ? .brandAccent : .textTertiary)

                                Text(fmt.rawValue)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(selectedFormat == fmt ? .textPrimary : .textSecondary)

                                Spacer()

                                if fmt == .m4a {
                                    Text("RECOMMENDED")
                                        .font(.system(size: 8, weight: .heavy))
                                        .foregroundColor(.emeraldAccent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.emeraldAccent.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(selectedFormat == fmt ? Color.elevatedSurface : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selectedFormat == fmt ? Color.brandAccent.opacity(0.5) : Color.borderHairline, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Extract Action Button
    private var extractActionButton: some View {
        Button(action: { startExtraction() }) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 16, weight: .bold))

                Text("Extract Audio Now")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.brandAccent, Color(hex: "E94057")],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.brandAccent.opacity(0.35), radius: 10, y: 4)
        }
        .disabled(isExtracting)
    }

    // MARK: - Progress Card
    private var progressCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(spacing: 8) {
                HStack {
                    Text("EXTRACTING AUDIO...")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.brandAccent)
                    Spacer()
                    Text("\(Int(extractProgress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                }

                ProgressView(value: extractProgress, total: 1.0)
                    .tint(Color.brandAccent)
            }
        }
    }

    // MARK: - Success Result Card
    private func successResultCard(outputUrl: URL) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.emeraldAccent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio Extracted Successfully!")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Text(outputUrl.lastPathComponent)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.textMuted)
                            .lineLimit(1)
                    }

                    Spacer()
                }

                Divider().background(Color.borderHairline)

                Button(action: { showShareSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Save to Files / Share Audio")
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
        self.extractedResult = nil

        let asset = AVURLAsset(url: url)
        Task {
            let duration = (try? await asset.load(.duration)) ?? .zero
            let durationSec = CMTimeGetSeconds(duration)
            let durMs = Int64(durationSec * 1000)

            let info = await AudioExtractEngine.shared.inspectAudioTrack(url: url)

            await MainActor.run {
                self.trackInfo = info
                self.totalDurationMs = durMs
                self.startMs = 0
                self.endMs = durMs

                // Setup AVPlayer for audio preview
                let playerItem = AVPlayerItem(url: url)
                self.avPlayer = AVPlayer(playerItem: playerItem)
            }
        }
    }

    private func togglePlayback() {
        guard let player = avPlayer else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func startExtraction() {
        guard let url = videoUrl else { return }
        isExtracting = true
        extractProgress = 0.0

        let finalStart = trimRangeEnabled ? startMs : 0
        let finalEnd = trimRangeEnabled ? endMs : 0

        Task {
            let result = await AudioExtractEngine.shared.extractAudio(
                srcUrl: url,
                format: selectedFormat,
                startMs: finalStart,
                endMs: finalEnd
            ) { progress in
                self.extractProgress = progress
            }

            await MainActor.run {
                self.isExtracting = false
                if result.success {
                    self.extractedResult = result
                } else {
                    self.alertMessage = result.errorMessage ?? "Audio extraction failed"
                    self.showAlert = true
                }
            }
        }
    }

    private func reset() {
        avPlayer?.pause()
        avPlayer = nil
        videoUrl = nil
        trackInfo = nil
        extractedResult = nil
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

// MARK: - Audio Share Sheet
struct AudioShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
