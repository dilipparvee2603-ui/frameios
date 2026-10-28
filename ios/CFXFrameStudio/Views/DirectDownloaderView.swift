import SwiftUI
import AVFoundation

struct DirectDownloaderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = DirectDownloadEngine()

    @State private var inputUrl: String = ""
    @State private var showShareSheet: Bool = false
    @State private var recentDownloads: [URL] = []

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    headerBar
                    inputCard

                    if engine.isDownloading {
                        downloadProgressCard
                    }

                    if let fileUrl = engine.downloadedFileUrl, let inspection = engine.mediaInspection {
                        downloadResultCard(fileUrl: fileUrl, inspection: inspection)
                    }

                    if let error = engine.errorMessage {
                        errorBanner(error: error)
                    }

                    if !recentDownloads.isEmpty {
                        recentDownloadsSection
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            refreshRecentDownloads()
        }
        .onChange(of: engine.downloadedFileUrl) { newUrl in
            if newUrl != nil {
                refreshRecentDownloads()
                // If Photos rejected or non-standard, automatically trigger share sheet
                if !engine.savedToPhotos {
                    showShareSheet = true
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = engine.downloadedFileUrl {
                ShareActivityView(activityItems: [url])
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.surfaceCard)
                    .clipShape(Circle())
            }

            Text("DIRECT LINK DOWNLOADER")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.textPrimary)

            Spacer()

            Button(action: { pasteFromClipboard() }) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.skyAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.surfaceCard)
                    .clipShape(Circle())
            }
        }
    }

    @ViewBuilder
    private var inputCard: some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "link.badge.plus")
                        .foregroundColor(.skyAccent)
                        .font(.system(size: 14, weight: .bold))
                    Text("DIRECT MEDIA LINK")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textMuted)
                        .tracking(1.0)
                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField("https://... (Cloudflare, S3, CDN, raw video/image)", text: $inputUrl)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.borderHairline, lineWidth: 1)
                        )

                    if !inputUrl.isEmpty {
                        Button(action: { inputUrl = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.textTertiary)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button(action: { pasteFromClipboard() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 12, weight: .bold))
                            Text("Paste")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.skyAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.skyAccent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Spacer()

                    Button(action: {
                        engine.startDownload(urlString: inputUrl)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("Start Download")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(inputUrl.isEmpty ? LinearGradient.brandGradient.opacity(0.4) : LinearGradient.brandGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(inputUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isDownloading)
                }
            }
        }
    }

    @ViewBuilder
    private var downloadProgressCard: some View {
        GlassCard(cornerRadius: 16, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .skyAccent))
                            .scaleEffect(0.8)
                        Text("Downloading Media...")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.textPrimary)
                    }

                    Spacer()

                    Text("\(Int(engine.progress * 100))%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.skyAccent)
                }

                // Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.elevatedSurface)
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [Color.skyAccent, Color.brandAccent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * CGFloat(engine.progress)), height: 6)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("\(formatBytes(engine.bytesWritten)) / \(formatBytes(engine.totalBytes))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.textMuted)

                    Spacer()

                    Text("\(String(format: "%.1f", engine.downloadSpeedMBs)) MB/s")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.emeraldAccent)
                }

                Button(action: { engine.cancelDownload() }) {
                    Text("Cancel Download")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private func downloadResultCard(fileUrl: URL, inspection: MediaInspection) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                // Header Status
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.emeraldAccent)
                        .font(.system(size: 18))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileUrl.lastPathComponent)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)

                        Text(engine.savedToPhotos
                             ? "✓ Saved to Photos Library & CFX Studio Files"
                             : "Saved to On My iPhone > CFX Studio")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(engine.savedToPhotos ? .emeraldAccent : .amberAccent)
                    }
                    Spacer()
                }

                // Incompatibility explanation note if not saved to Photos
                if !engine.savedToPhotos, let reason = inspection.incompatibilityReason {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.amberAccent)
                            .font(.system(size: 12))
                            .padding(.top, 1)

                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundColor(.textMuted)
                    }
                    .padding(8)
                    .background(Color.amberAccent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Codec & Media Metadata Chips
                VStack(alignment: .leading, spacing: 6) {
                    Text("MEDIA CODECS & CONTAINER")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.textTertiary)
                        .tracking(1.0)

                    HStack(spacing: 6) {
                        codecChip(title: "Container", value: inspection.container, color: .skyAccent)
                        if inspection.isVideo {
                            codecChip(title: "Video", value: inspection.videoCodec, color: .emeraldAccent)
                            codecChip(title: "Audio", value: inspection.audioCodec, color: .amberAccent)
                        } else {
                            codecChip(title: "Resolution", value: "\(inspection.width)×\(inspection.height)", color: .emeraldAccent)
                        }
                    }
                }

                Divider().background(Color.borderHairline)

                // Actions: Share & Send to Tools
                VStack(spacing: 8) {
                    Button(action: { showShareSheet = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                            Text("Share / Save to Files")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.elevatedSurface)
                        .foregroundColor(.skyAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.skyAccent.opacity(0.3), lineWidth: 1)
                        )
                    }

                    HStack(spacing: 8) {
                        if inspection.isVideo {
                            NavigationLink(destination: VideoTrimmerView()) {
                                toolPipelineButton(icon: "scissors", label: "Trimmer")
                            }

                            NavigationLink(destination: FrameExporterView()) {
                                toolPipelineButton(icon: "photo.stack", label: "Exporter")
                            }

                            NavigationLink(destination: VideoConverterView()) {
                                toolPipelineButton(icon: "arrow.triangle.2.circlepath", label: "Converter")
                            }
                        } else {
                            NavigationLink(destination: ImageCropperView()) {
                                toolPipelineButton(icon: "crop", label: "Open Cropper")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func codecChip(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title + ":")
                .font(.system(size: 10))
                .foregroundColor(.textMuted)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.borderHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func toolPipelineButton(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(Color.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func errorBanner(error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.brandVibrant)
                .font(.system(size: 14))

            Text(error)
                .font(.system(size: 12))
                .foregroundColor(.textPrimary)

            Spacer()
        }
        .padding(12)
        .background(Color.brandAccent.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.brandAccent.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var recentDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CFX STUDIO STORAGE (ON MY IPHONE)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.textMuted)
                    .tracking(1.0)
                Spacer()
                Text("\(recentDownloads.count) files")
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
            }

            VStack(spacing: 6) {
                ForEach(recentDownloads.prefix(5), id: \.self) { url in
                    recentFileRow(url: url)
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func recentFileRow(url: URL) -> some View {
        GlassCard(cornerRadius: 12, padding: 10) {
            HStack(spacing: 10) {
                let isVid = ["mp4", "mov", "mkv", "webm", "m4v"].contains(url.pathExtension.lowercased())
                Image(systemName: isVid ? "video.fill" : "photo.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isVid ? .skyAccent : .amberAccent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let size = attrs[.size] as? Int64 {
                        Text(formatBytes(size))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.textMuted)
                    }
                }

                Spacer()

                Button(action: {
                    engine.downloadedFileUrl = url
                    showShareSheet = true
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                        .foregroundColor(.skyAccent)
                        .padding(6)
                        .background(Color.elevatedSurface)
                        .clipShape(Circle())
                }
            }
        }
    }

    // MARK: - Helpers

    private func pasteFromClipboard() {
        if let clip = UIPasteboard.general.string {
            inputUrl = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1024.0)
        }
    }

    private func refreshRecentDownloads() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
            recentDownloads = files.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
        }
    }
}
