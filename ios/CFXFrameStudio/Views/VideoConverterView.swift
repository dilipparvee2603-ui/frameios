import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct VideoConverterView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhotosItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false

    @State private var videoUrl: URL? = nil
    @State private var videoInfo: VideoInfo? = nil

    @State private var targetContainer: ExportContainer = .mp4
    @State private var targetCodec: ExportCodec = .auto
    @State private var includeAudio: Bool = true

    @State private var isConverting: Bool = false
    @State private var convertProgress: Float = 0.0

    @State private var isRemuxing: Bool = false
    @State private var remuxProgress: Double = 0.0
    @State private var remuxSpeedText: String = ""
    @State private var convertedFileUrl: URL? = nil
    @State private var showShareSheet: Bool = false

    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Header Bar
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.textPrimary)
                                .frame(width: 36, height: 36)
                                .background(Color.surfaceCard)
                                .clipShape(Circle())
                        }

                        Text("VIDEO CONVERTER STUDIO")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    if videoUrl == nil {
                        // Import Options Card
                        VStack(spacing: 14) {
                            // Pick from Photos
                            PhotosPicker(selection: $selectedPhotosItem, matching: .videos) {
                                GlassCard(cornerRadius: 18, padding: 24) {
                                    HStack(spacing: 16) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.emeraldAccent.opacity(0.15))
                                                .frame(width: 48, height: 48)
                                            Image(systemName: "photo.on.rectangle.angled")
                                                .font(.system(size: 22, weight: .bold))
                                                .foregroundColor(.emeraldAccent)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Import from Camera Roll")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.textPrimary)
                                            Text("Convert MP4, MOV, Cinematic videos")
                                                .font(.system(size: 12))
                                                .foregroundColor(.textMuted)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.textTertiary)
                                    }
                                }
                            }

                            // Pick from Files App (supports MKV, WebM, etc.)
                            Button(action: { showFilePicker = true }) {
                                GlassCard(cornerRadius: 18, padding: 24) {
                                    HStack(spacing: 16) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.skyAccent.opacity(0.15))
                                                .frame(width: 48, height: 48)
                                            Image(systemName: "folder.fill")
                                                .font(.system(size: 22, weight: .bold))
                                                .foregroundColor(.skyAccent)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Import from Files App")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.textPrimary)
                                            Text("Convert MOV, MP4, MKV, WebM, ProRes files")
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
                        // Selected Video Settings & Actions
                        if let info = videoInfo {
                            sourceVideoCard(info: info)
                            containerCard
                            codecDropdownCard(info: info)
                            audioSettingCard
                            convertActionSection(info: info)
                            Spacer(minLength: 24)
                        }
                    }
                }
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
                                    .foregroundColor(.emeraldAccent)

                                Text("Optimizing Video for iOS")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.textPrimary)

                                Spacer()

                                Text("\(Int(remuxProgress * 100))%")
                                    .font(.system(size: 22, weight: .black, design: .rounded))
                                    .foregroundColor(.emeraldAccent)
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.elevatedSurface)
                                        .frame(height: 8)

                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(LinearGradient(colors: [Color.emeraldAccent, Color.brandAccent], startPoint: .leading, endPoint: .trailing))
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
        .onChange(of: selectedPhotosItem) { newItem in
            Task {
                if let item = newItem {
                    await loadFromPhotos(item: item)
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
            if let outUrl = convertedFileUrl {
                ShareActivityView(activityItems: [outUrl])
            }
        }
        .alert(alertMessage ?? "", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    private func codecDescription(_ codec: ExportCodec, sourceCodec: String) -> String {
        switch codec {
        case .auto:
            return "Lossless stream-copy — keeps \(sourceCodec) without re-encoding (0% loss)"
        case .h264:
            return "Universal compatibility with all devices and web players"
        case .hevc:
            return "50% smaller size at original resolution with HDR10/Dolby Vision"
        case .prores:
            return "Apple ProRes 422 master format for professional editing in Final Cut"
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func sourceVideoCard(info: VideoInfo) -> some View {
        GlassCard(cornerRadius: 16, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SOURCE VIDEO")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textTertiary)
                        .tracking(1.0)

                    Spacer()

                    Button("Change") {
                        self.videoUrl = nil
                        self.videoInfo = nil
                        self.convertedFileUrl = nil
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.brandAccent)
                }

                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.elevatedSurface)
                            .frame(width: 44, height: 44)
                        Image(systemName: "film.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.gradientStart)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(videoUrl?.lastPathComponent ?? "Video")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text("\(info.width) × \(info.height)")
                                .foregroundColor(.emeraldAccent)
                            Text("•")
                                .foregroundColor(.textTertiary)
                            Text(String(format: "%.0f FPS", info.fps))
                                .foregroundColor(.textMuted)
                            Text("•")
                                .foregroundColor(.textTertiary)
                            Text(info.formattedDuration)
                                .foregroundColor(.textMuted)
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))

                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 9))
                                Text(info.videoCodec)
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.skyAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.skyAccent.opacity(0.12))
                            .cornerRadius(6)

                            if info.audioCodec != "None" {
                                HStack(spacing: 4) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 9))
                                    Text(info.audioCodec)
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .foregroundColor(.emeraldAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.emeraldAccent.opacity(0.12))
                                .cornerRadius(6)
                            }

                            Text((videoUrl?.pathExtension.uppercased() ?? "MP4"))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.textMuted)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.elevatedSurface)
                                .cornerRadius(6)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var containerCard: some View {
        GlassCard(cornerRadius: 14, padding: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OUTPUT CONTAINER")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textTertiary)
                        .tracking(1.0)
                    Text("File container format")
                        .font(.system(size: 11))
                        .foregroundColor(.textMuted)
                }

                Spacer()

                HStack(spacing: 8) {
                    ForEach(ExportContainer.allCases) { container in
                        Button(action: { targetContainer = container }) {
                            HStack(spacing: 4) {
                                if targetContainer == container {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Text(container.rawValue)
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(targetContainer == container ? Color.brandAccent : Color.elevatedSurface)
                            .foregroundColor(targetContainer == container ? .white : .textMuted)
                            .cornerRadius(8)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func codecDropdownCard(info: VideoInfo) -> some View {
        GlassCard(cornerRadius: 14, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("VIDEO CODEC")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textTertiary)
                        .tracking(1.0)

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                        Text("100% Original Resolution")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.emeraldAccent)
                }

                Menu {
                    ForEach(ExportCodec.allCases) { codec in
                        Button(action: { targetCodec = codec }) {
                            if targetCodec == codec {
                                Label(codec.rawValue, systemImage: "checkmark")
                            } else {
                                Text(codec.rawValue)
                            }
                        }
                    }
                } label: {
                    codecMenuLabel(info: info)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func codecMenuLabel(info: VideoInfo) -> some View {
        let desc = codecDescription(targetCodec, sourceCodec: info.videoCodec)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(targetCodec.rawValue)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.textPrimary)
                    if targetCodec == .auto {
                        Text("DIRECT STREAM")
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.emeraldAccent.opacity(0.15))
                            .foregroundColor(.emeraldAccent)
                            .cornerRadius(4)
                    }
                }
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 4) {
                Text("Select")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.brandAccent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.brandAccent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.brandAccent.opacity(0.12))
            .cornerRadius(6)
        }
        .padding(10)
        .background(Color.elevatedSurface)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.borderHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var audioSettingCard: some View {
        GlassCard(cornerRadius: 14, padding: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(includeAudio ? Color.emeraldAccent.opacity(0.15) : Color(hex: "FF5252").opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: includeAudio ? "music.note" : "speaker.slash")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(includeAudio ? .emeraldAccent : Color(hex: "FF5252"))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(includeAudio ? "Include Audio Track" : "Mute Audio on Conversion")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text(includeAudio ? "Preserve original audio track" : "Produce 100% silent video")
                        .font(.system(size: 11))
                        .foregroundColor(.textMuted)
                }

                Spacer()

                Toggle("", isOn: $includeAudio)
                    .labelsHidden()
                    .tint(.emeraldAccent)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func convertActionSection(info: VideoInfo) -> some View {
        VStack(spacing: 12) {
            // Resolution Guarantee Badge
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.emeraldAccent)
                    .font(.system(size: 14))
                Text("Guaranteed: Resolution preserved at \(info.width) × \(info.height)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 16)

            // Conversion Progress with Active Stop Button
            if isConverting {
                GlassCard(cornerRadius: 14, padding: 14) {
                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Converting Video...")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.textPrimary)
                                Text(String(format: "Progress: %.0f%%", convertProgress * 100.0))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.emeraldAccent)
                            }

                            Spacer()

                            Button(action: stopConversion) {
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

                        ProgressView(value: convertProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .brandAccent))
                    }
                }
                .padding(.horizontal, 16)
            }

            // Convert Action / Stop Button
            if isConverting {
                Button(action: stopConversion) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text("Stop Conversion Process")
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
                Button(action: startConversion) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .bold))
                        Text("Convert to \(targetContainer.rawValue) (\(info.width)×\(info.height))")
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

            // Share / Save to Files Button if finished
            if let outUrl = convertedFileUrl {
                Button(action: { showShareSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .bold))
                        Text("Share / Save Converted File")
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

    private func loadFromPhotos(item: PhotosPickerItem) async {
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
                    self.convertedFileUrl = nil
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
                    self.convertedFileUrl = nil
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = "Failed to load video: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    private func stopConversion() {
        VideoConvertEngine.shared.cancel()
        isConverting = false
        convertProgress = 0.0
    }

    private func startConversion() {
        guard let url = videoUrl, !isConverting else { return }
        isConverting = true
        convertProgress = 0.0
        convertedFileUrl = nil

        Task {
            let result = await VideoConvertEngine.shared.convertVideo(
                srcUrl: url,
                targetContainer: targetContainer,
                targetCodec: targetCodec,
                includeAudio: includeAudio,
                onProgress: { p in
                    self.convertProgress = p
                }
            )

            await MainActor.run {
                self.isConverting = false
                if result.errorMessage == "OPERATION_CANCELLED" {
                    // User tapped Stop — reset cleanly without error popups
                    return
                }
                if result.success, let outUrl = result.outputUrl {
                    self.convertedFileUrl = outUrl
                    if result.errorMessage != nil {
                        // Automatically open Save to Files / Share Sheet!
                        self.showShareSheet = true
                    } else {
                        self.alertMessage = "✓ Video converted successfully to \(targetContainer.rawValue) at original resolution!"
                        self.showAlert = true
                    }
                } else {
                    self.alertMessage = "Conversion Error: \(result.errorMessage ?? "Unknown error")"
                    self.showAlert = true
                }
            }
        }
    }
}

// Share sheet for saving or sharing converted files
struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        return UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
