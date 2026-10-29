import SwiftUI
import PhotosUI
import AVKit

// MARK: - Video Stitcher View
struct VideoStitcherView: View {
    @Environment(\.dismiss) private var dismiss

    // Clip items list
    @State private var clips: [StitchClipItem] = []
    @State private var selectedMode: StitchMode = .lossless

    // UI State
    @State private var isProcessing: Bool = false
    @State private var processProgress: Float = 0.0
    @State private var processStatusText: String = ""
    @State private var showPhotosPicker: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var photoPickerItems: [PhotosPickerItem] = []

    // Result & Preview
    @State private var resultVideoUrl: URL? = nil
    @State private var resultDurationMs: Int64 = 0
    @State private var isLosslessResult: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var showSaveSuccessToast: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showErrorAlert: Bool = false

    // Player for result
    @State private var resultPlayer: AVPlayer? = nil

    private var totalDurationFormatted: String {
        let totalMs = clips.reduce(0) { $0 + $1.durationMs }
        let totalSeconds = Double(totalMs) / 1000.0
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let fraction = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, fraction)
    }

    private var compatibilityCheck: (canLossless: Bool, reason: String) {
        VideoStitchEngine.shared.canLosslessStitch(clips: clips)
    }

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                navigationHeader

                if let outUrl = resultVideoUrl {
                    // Result & Preview Screen
                    resultPreviewView(url: outUrl)
                } else {
                    // Editor & Clip Queue
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            if clips.isEmpty {
                                emptyStateCard
                            } else {
                                // Compatibility Banner
                                compatibilityBanner

                                // Queue Header + Actions
                                queueHeaderSection

                                // Re-orderable Clips List
                                clipsListSection

                                // Stitch Configuration
                                modeSelectorSection
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 100)
                    }

                    // Bottom Action Bar
                    if !clips.isEmpty {
                        bottomActionBar
                    }
                }
            }

            // Processing Overlay
            if isProcessing {
                processingOverlay
            }

            // Success Toast
            if showSaveSuccessToast {
                saveSuccessToast
            }
        }
        .navigationBarHidden(true)
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoPickerItems,
            matching: .videos,
            photoLibrary: .shared()
        )
        .onChange(of: photoPickerItems) { newItems in
            loadPhotosPickerItems(newItems)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: true
        ) { result in
            handleFileImporter(result: result)
        }
        .alert("Stitch Failed", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unexpected error occurred.")
        }
        .sheet(isPresented: $showShareSheet) {
            if let outUrl = resultVideoUrl {
                ShareActivityView(activityItems: [outUrl])
            }
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
                    Text("CLIP STITCHER")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text("0% LOSS")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(.brandAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.brandAccent.opacity(0.14))
                        .clipShape(Capsule())
                }

                Text("Lossless Multi-Video Concatenator")
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            if !clips.isEmpty && resultVideoUrl == nil {
                Menu {
                    Button(action: { showPhotosPicker = true }) {
                        Label("Add from Photos", systemImage: "photo.stack")
                    }
                    Button(action: { showFilePicker = true }) {
                        Label("Add from Files", systemImage: "folder")
                    }
                    Divider()
                    Button(role: .destructive, action: { clips.removeAll() }) {
                        Label("Clear All Clips", systemImage: "trash")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("Add")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.brandAccent)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    // MARK: - Compatibility Banner
    private var compatibilityBanner: some View {
        let check = compatibilityCheck
        return GlassCard(cornerRadius: 14, padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: check.canLossless ? "bolt.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(check.canLossless ? .emeraldAccent : .amberAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(check.canLossless ? "100% Lossless Stream-Copy Compatible" : "Clip Parameters Differ")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(check.reason)
                        .font(.system(size: 10))
                        .foregroundColor(.textMuted)
                }

                Spacer()

                if check.canLossless {
                    Text("0% LOSS")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundColor(.emeraldAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.emeraldAccent.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Queue Header Section
    private var queueHeaderSection: some View {
        HStack {
            Text("STITCH QUEUE (\(clips.count) CLIPS)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.textSecondary)
                .tracking(0.6)

            Spacer()

            Text("Total: \(totalDurationFormatted)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.brandAccent)
        }
    }

    // MARK: - Clips List Section
    private var clipsListSection: some View {
        VStack(spacing: 10) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                clipCard(clip: clip, index: index)
            }
        }
    }

    private func clipCard(clip: StitchClipItem, index: Int) -> some View {
        GlassCard(cornerRadius: 14, padding: 10) {
            HStack(spacing: 12) {
                // Order Index Pill
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.elevatedSurface)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.borderHairline, lineWidth: 1)
                        )

                    Text("#\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                }

                // Thumbnail
                if let thumb = clip.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.elevatedSurface)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "film")
                                .foregroundColor(.textTertiary)
                        )
                }

                // Metadata Details
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.filename)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(clip.durationFormatted)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.emeraldAccent)

                        Text("•")
                            .foregroundColor(.textTertiary)
                            .font(.system(size: 8))

                        Text(clip.resolutionLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.textMuted)

                        Text("•")
                            .foregroundColor(.textTertiary)
                            .font(.system(size: 8))

                        Text(clip.videoCodec.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.skyAccent)
                    }
                }

                Spacer()

                // Re-order and Delete controls
                HStack(spacing: 4) {
                    Button(action: { moveClipUp(index: index) }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(index > 0 ? .textSecondary : .textTertiary.opacity(0.3))
                            .frame(width: 28, height: 28)
                            .background(Color.elevatedSurface)
                            .clipShape(Circle())
                    }
                    .disabled(index == 0)

                    Button(action: { moveClipDown(index: index) }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(index < clips.count - 1 ? .textSecondary : .textTertiary.opacity(0.3))
                            .frame(width: 28, height: 28)
                            .background(Color.elevatedSurface)
                            .clipShape(Circle())
                    }
                    .disabled(index == clips.count - 1)

                    Button(action: { removeClip(at: index) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.brandAccent)
                            .frame(width: 28, height: 28)
                            .background(Color.elevatedSurface)
                            .clipShape(Circle())
                    }
                }
            }
        }
    }

    // MARK: - Mode Selector Section
    private var modeSelectorSection: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CONCATENATION ENGINE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.textSecondary)
                    .tracking(0.6)

                VStack(spacing: 8) {
                    ForEach(StitchMode.allCases) { mode in
                        let isSelected = selectedMode == mode
                        let isLosslessDisabled = (mode == .lossless && !compatibilityCheck.canLossless)

                        Button(action: {
                            if !isLosslessDisabled {
                                selectedMode = mode
                            }
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(mode.rawValue)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(isLosslessDisabled ? .textTertiary : (isSelected ? .textPrimary : .textSecondary))

                                        Text(mode.badge)
                                            .font(.system(size: 8, weight: .heavy))
                                            .foregroundColor(isSelected ? .brandAccent : .textTertiary)
                                    }

                                    Text(mode.description)
                                        .font(.system(size: 10))
                                        .foregroundColor(.textMuted)
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer()

                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .brandAccent : .textTertiary)
                                    .font(.system(size: 18))
                            }
                            .padding(10)
                            .background(isSelected ? Color.brandAccent.opacity(0.1) : Color.elevatedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isSelected ? Color.brandAccent.opacity(0.5) : Color.borderHairline, lineWidth: 1)
                            )
                        }
                        .disabled(isLosslessDisabled)
                    }
                }
            }
        }
    }

    // MARK: - Empty State Card
    private var emptyStateCard: some View {
        GlassCard(cornerRadius: 20, padding: 24) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.brandAccent.opacity(0.12))
                        .frame(width: 72, height: 72)

                    Image(systemName: "film.stack")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.brandAccent)
                }

                VStack(spacing: 6) {
                    Text("Select 2 or More Clips to Stitch")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text("Merge multi-part videos, scenes, or trimmed clips into one continuous file with 0% quality loss.")
                        .font(.system(size: 12))
                        .foregroundColor(.textMuted)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button(action: { showPhotosPicker = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.stack")
                            Text("Photos Library")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.brandAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Button(action: { showFilePicker = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("Files App")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.borderHairline, lineWidth: 1)
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Bottom Action Bar
    private var bottomActionBar: some View {
        VStack(spacing: 8) {
            Button(action: startStitching) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(selectedMode == .lossless ? "Instant Lossless Stitch (0% Loss)" : "Smart Match Stitch")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(LinearGradient.brandGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.brandAccent.opacity(0.4), radius: 8, x: 0, y: 3)
            }
            .disabled(clips.count < 2)
            .opacity(clips.count < 2 ? 0.5 : 1.0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.surfaceCard)
        .overlay(
            Rectangle()
                .fill(Color.borderHairline)
                .frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - Result & Preview View
    private func resultPreviewView(url: URL) -> some View {
        VStack(spacing: 16) {
            // Success Card
            GlassCard(cornerRadius: 18, padding: 16) {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.emeraldAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stitch Completed Successfully")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.textPrimary)

                            Text(isLosslessResult ? "100% Bit-For-Bit Lossless Stream Copy" : "Smart Normalized & Re-encoded")
                                .font(.system(size: 11))
                                .foregroundColor(.textMuted)
                        }

                        Spacer()

                        if isLosslessResult {
                            Text("0% LOSS")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.emeraldAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.emeraldAccent.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }

                    // Video Player
                    if let player = resultPlayer {
                        VideoPlayer(player: player)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            // Export Actions
            HStack(spacing: 12) {
                Button(action: saveResultToPhotos) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save to Photos")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.emeraldAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button(action: { showShareSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.elevatedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.borderHairline, lineWidth: 1)
                    )
                }
            }

            Button(action: resetStitcher) {
                Text("Stitch Another Video")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textMuted)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onAppear {
            resultPlayer = AVPlayer(url: url)
            resultPlayer?.play()
        }
    }

    // MARK: - Processing Overlay
    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color.brandAccent))
                    .scaleEffect(1.4)

                VStack(spacing: 6) {
                    Text("Stitching Video Clips...")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(processStatusText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.textMuted)
                }

                if processProgress > 0.05 {
                    ProgressView(value: processProgress, total: 1.0)
                        .tint(Color.brandAccent)
                        .padding(.horizontal, 40)
                }

                Button(action: cancelStitching) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.brandAccent)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.elevatedSurface)
                        .clipShape(Capsule())
                }
                .padding(.top, 6)
            }
            .padding(24)
            .background(Color.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.borderHairline, lineWidth: 1)
            )
            .padding(24)
        }
    }

    // MARK: - Toast
    private var saveSuccessToast: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.emeraldAccent)
                Text("Saved to Photos Successfully!")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.elevatedSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Color.emeraldAccent.opacity(0.5), lineWidth: 1)
            )
            .shadow(radius: 8)
            .padding(.bottom, 30)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Logic & Actions
    private func moveClipUp(index: Int) {
        guard index > 0 else { return }
        clips.swapAt(index, index - 1)
    }

    private func moveClipDown(index: Int) {
        guard index < clips.count - 1 else { return }
        clips.swapAt(index, index + 1)
    }

    private func removeClip(at index: Int) {
        clips.remove(at: index)
    }

    private func loadPhotosPickerItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let movie = try? await item.loadTransferable(type: MovieTransferable.self) {
                    let clip = await VideoStitchEngine.shared.probeClip(url: movie.url)
                    await MainActor.run {
                        self.clips.append(clip)
                    }
                }
            }
            await MainActor.run {
                self.photoPickerItems.removeAll()
            }
        }
    }

    private func handleFileImporter(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }

                    let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: tempUrl)
                    try? FileManager.default.copyItem(at: url, to: tempUrl)

                    let clip = await VideoStitchEngine.shared.probeClip(url: tempUrl)
                    await MainActor.run {
                        self.clips.append(clip)
                    }
                }
            }
        case .failure(let error):
            self.errorMessage = error.localizedDescription
            self.showErrorAlert = true
        }
    }

    private func startStitching() {
        guard clips.count >= 2 else { return }
        isProcessing = true
        processProgress = 0.0
        processStatusText = "Preparing clips..."

        Task {
            let res = await VideoStitchEngine.shared.stitchVideos(
                clips: clips,
                mode: selectedMode
            ) { progress, status in
                Task { @MainActor in
                    self.processProgress = progress
                    self.processStatusText = status
                }
            }

            await MainActor.run {
                self.isProcessing = false
                if res.success, let outUrl = res.outputUrl {
                    self.resultVideoUrl = outUrl
                    self.resultDurationMs = res.durationMs
                    self.isLosslessResult = res.isLosslessCopy
                } else {
                    self.errorMessage = res.errorMessage ?? "Concatenation failed"
                    self.showErrorAlert = true
                }
            }
        }
    }

    private func cancelStitching() {
        VideoStitchEngine.shared.cancel()
        isProcessing = false
    }

    private func saveResultToPhotos() {
        guard let url = resultVideoUrl else { return }
        Task {
            do {
                _ = try await VideoStitchEngine.shared.exportToPhotos(fileUrl: url)
                await MainActor.run {
                    withAnimation { self.showSaveSuccessToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation { self.showSaveSuccessToast = false }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showErrorAlert = true
                }
            }
        }
    }

    private func resetStitcher() {
        resultPlayer?.pause()
        resultPlayer = nil
        resultVideoUrl = nil
        clips.removeAll()
    }
}
