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

    @State private var includeAudioInExport: Bool = true
    @State private var isExporting: Bool = false
    @State private var exportProgress: Float = 0.0

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
                                            Text("Trim MP4, MOV, MKV from Downloads & iCloud")
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
                                            HStack(spacing: 4) {
                                                Image(systemName: "clock")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.brandAccent)
                                                Text(formatMsToTimecode(playerModel.currentPositionMs))
                                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.textPrimary)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.elevatedSurface)
                                            .cornerRadius(6)
                                        }

                                        Spacer()

                                        let trimSec = Double(max(0, outPointMs - inPointMs)) / 1000.0
                                        Text(String(format: "Cut Duration: %.2fs", trimSec))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.emeraldAccent)
                                    }

                                    // Interactive Playhead & Trim Scrubber
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
                                    }

                                    // In-Point & Out-Point Selection Controls
                                    HStack(spacing: 8) {
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

                                        Button(action: { activeTimecodeTarget = .inPoint }) {
                                            Text(formatMsToTimecode(inPointMs))
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundColor(.textMuted)
                                        }

                                        Text("→")
                                            .foregroundColor(.textTertiary)

                                        Button(action: { activeTimecodeTarget = .outPoint }) {
                                            Text(formatMsToTimecode(outPointMs))
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundColor(.textMuted)
                                        }

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

                            // Export Progress Indicator
                            if isExporting {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView(value: exportProgress, total: 1.0)
                                        .progressViewStyle(LinearProgressViewStyle(tint: .brandAccent))
                                    Text(String(format: "Trimming clip: %.0f%%", exportProgress * 100.0))
                                        .font(.system(size: 11))
                                        .foregroundColor(.textMuted)
                                }
                                .padding(.horizontal, 16)
                            }

                            // Export Action Button
                            Button(action: exportTrimmedVideo) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(isExporting ? "Exporting Video..." : (includeAudioInExport ? "Export Trimmed Video" : "Export Muted Video Clip"))
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
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie, UTType(filenameExtension: "mkv") ?? .movie],
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
        guard url.startAccessingSecurityScopedResource() else {
            alertMessage = "Permission denied to read file"
            showAlert = true
            return
        }

        defer { url.stopAccessingSecurityScopedResource() }

        let tempDir = FileManager.default.temporaryDirectory
        let destUrl = tempDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destUrl)

        do {
            try FileManager.default.copyItem(at: url, to: destUrl)
            Task {
                let info = try await VideoEngine.shared.extractVideoInfo(from: destUrl)
                await MainActor.run {
                    self.videoUrl = destUrl
                    self.videoInfo = info
                    self.inPointMs = 0
                    self.outPointMs = info.durationMs
                    self.playerModel.setup(with: destUrl) { ms in
                        if self.outPointMs > 0 && ms >= self.outPointMs && self.playerModel.isPlaying {
                            self.playerModel.seek(to: self.inPointMs)
                        }
                    }
                }
            }
        } catch {
            alertMessage = "Failed to access file: \(error.localizedDescription)"
            showAlert = true
        }
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
                onProgress: { p in
                    self.exportProgress = p
                }
            )

            await MainActor.run {
                self.isExporting = false
                if result.success {
                    self.alertMessage = includeAudioInExport ? "✓ Trimmed video saved to Camera Roll!" : "✓ Trimmed silent video saved to Camera Roll!"
                } else {
                    self.alertMessage = "Export Error: \(result.errorMessage ?? "Unknown error")"
                }
                self.showAlert = true
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
