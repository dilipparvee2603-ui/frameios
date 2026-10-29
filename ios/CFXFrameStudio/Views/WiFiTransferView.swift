import SwiftUI
import PhotosUI
import CoreImage.CIFilterBuiltins

// MARK: - Wi-Fi Transfer View
struct WiFiTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var server = WiFiTransferServer.shared

    @State private var showPhotosPicker: Bool = false
    @State private var selectedPhotosItems: [PhotosPickerItem] = []
    @State private var copiedToast: Bool = false
    @State private var qrImage: UIImage? = nil

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                navigationHeader

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // Server Status & Power Switch Card
                        serverControlCard

                        if server.isRunning, let urlStr = server.serverUrlString {
                            // Active Connection & QR Code Card
                            activeConnectionCard(urlStr: urlStr)

                            // Telemetry Stats Card
                            telemetryStatsCard

                            // Quick Settings Card
                            quickSettingsCard

                            // Files Ready on iPhone Section
                            filesListSection
                        } else {
                            // Offline Explanation Card
                            offlineGuideCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }

            // Copied Toast
            if copiedToast {
                copiedNotificationToast
            }
        }
        .navigationBarHidden(true)
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $selectedPhotosItems,
            matching: .videos,
            photoLibrary: .shared()
        )
        .onChange(of: selectedPhotosItems) { newItems in
            exportPhotosToDocuments(items: newItems)
        }
        .onAppear {
            if !server.isRunning {
                server.startServer()
            }
            updateQrCode()
        }
        .onChange(of: server.localIP) { _ in
            updateQrCode()
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
                    Text("WI-FI PC TRANSFER")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(server.isRunning ? "ONLINE" : "OFFLINE")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundColor(server.isRunning ? .emeraldAccent : .textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background((server.isRunning ? Color.emeraldAccent : Color.textTertiary).opacity(0.14))
                        .clipShape(Capsule())
                }

                Text("Wireless iPhone ↔ PC Sync without iTunes")
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            Button(action: { server.refreshSharedFiles() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Color.elevatedSurface)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.borderHairline, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    // MARK: - Server Control Card
    private var serverControlCard: some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill((server.isRunning ? Color.emeraldAccent : Color.textTertiary).opacity(0.14))
                        .frame(width: 48, height: 48)

                    Image(systemName: "wifi")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(server.isRunning ? .emeraldAccent : .textTertiary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(server.isRunning ? "Wi-Fi Server Active" : "Wi-Fi Server Stopped")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(server.statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.textMuted)
                }

                Spacer()

                Button(action: {
                    if server.isRunning {
                        server.stopServer()
                    } else {
                        server.startServer()
                        updateQrCode()
                    }
                }) {
                    Text(server.isRunning ? "Stop" : "Start")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(server.isRunning ? Color(hex: "E11D48") : Color.emeraldAccent)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Active Connection & QR Card
    private func activeConnectionCard(urlStr: String) -> some View {
        GlassCard(cornerRadius: 20, padding: 20) {
            VStack(spacing: 16) {
                Text("OPEN THIS URL ON YOUR PC BROWSER")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundColor(.skyAccent)
                    .tracking(0.8)

                // Large URL Pill
                HStack(spacing: 8) {
                    Text(urlStr)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .textSelection(.enabled)

                    Spacer()

                    Button(action: {
                        UIPasteboard.general.string = urlStr
                        withAnimation { copiedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { copiedToast = false }
                        }
                    }) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.skyAccent)
                            .padding(8)
                            .background(Color.skyAccent.opacity(0.14))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )

                // QR Code
                if let qr = qrImage {
                    VStack(spacing: 8) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 140, height: 140)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Text("Or scan QR code with your laptop / tablet camera")
                            .font(.system(size: 10.5))
                            .foregroundColor(.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Telemetry Stats Card
    private var telemetryStatsCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            HStack(spacing: 0) {
                statTile(
                    title: "CONNECTED",
                    value: "\(server.activeConnections)",
                    icon: "laptopcomputer",
                    color: .skyAccent
                )

                Divider()
                    .frame(height: 36)
                    .background(Color.borderHairline)

                statTile(
                    title: "RECEIVED",
                    value: ByteCountFormatter.string(fromByteCount: server.bytesReceived, countStyle: .file),
                    icon: "arrow.down.circle",
                    color: .emeraldAccent
                )

                Divider()
                    .frame(height: 36)
                    .background(Color.borderHairline)

                statTile(
                    title: "SENT",
                    value: ByteCountFormatter.string(fromByteCount: server.bytesSent, countStyle: .file),
                    icon: "arrow.up.circle",
                    color: .brandAccent
                )
            }
        }
    }

    private func statTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(.textTertiary)
            }

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Quick Settings Card
    private var quickSettingsCard: some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(spacing: 12) {
                Toggle(isOn: $server.autoSaveToPhotos) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Save PC Uploads to Photos")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text("Automatically adds uploaded videos to Camera Roll")
                            .font(.system(size: 10.5))
                            .foregroundColor(.textMuted)
                    }
                }
                .tint(Color.emeraldAccent)

                Divider().background(Color.borderHairline)

                Button(action: { showPhotosPicker = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.brandAccent)
                            .font(.system(size: 15))

                        Text("Share Video from Photos Library to PC")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Files Ready on iPhone Section
    private var filesListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FILES READY FOR PC (\(server.sharedFiles.count))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.textSecondary)
                    .tracking(0.6)

                Spacer()

                Text("Available for Download")
                    .font(.system(size: 10))
                    .foregroundColor(.textTertiary)
            }

            if server.sharedFiles.isEmpty {
                GlassCard(cornerRadius: 14, padding: 20) {
                    VStack(spacing: 6) {
                        Text("No files currently staged")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.textSecondary)
                        Text("Upload files from your PC or share videos from Photos using the button above.")
                            .font(.system(size: 11))
                            .foregroundColor(.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(server.sharedFiles) { file in
                        fileRow(file: file)
                    }
                }
            }
        }
    }

    private func fileRow(file: WiFiSharedFile) -> some View {
        GlassCard(cornerRadius: 12, padding: 10) {
            HStack(spacing: 10) {
                Image(systemName: file.isVideo ? "film" : "photo")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(file.isVideo ? .brandAccent : .skyAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.elevatedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(file.sizeFormatted)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.skyAccent)

                        Text("•")
                            .foregroundColor(.textTertiary)
                            .font(.system(size: 8))

                        Text(file.dateFormatted)
                            .font(.system(size: 9.5))
                            .foregroundColor(.textMuted)
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - Offline Guide Card
    private var offlineGuideCard: some View {
        GlassCard(cornerRadius: 18, padding: 20) {
            VStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 32))
                    .foregroundColor(.textTertiary)

                VStack(spacing: 6) {
                    Text("How Wi-Fi Direct Transfer Works")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text("1. Connect your iPhone and PC to the same Wi-Fi network (or turn on iPhone Personal Hotspot).\n2. Tap 'Start' to activate the local web server.\n3. Type the generated IP address into your PC browser (Chrome/Edge).\n4. Drag-and-drop 4K files, download trimmed clips, or send MKVs wirelessly at 100 MB/s.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.textMuted)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                }
            }
        }
    }

    // MARK: - Copied Notification Toast
    private var copiedNotificationToast: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.emeraldAccent)
                Text("URL Copied to Clipboard!")
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

    // MARK: - Helpers
    private func updateQrCode() {
        guard let url = server.serverUrlString else {
            qrImage = nil
            return
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            qrImage = nil
            return
        }
        filter.setValue(url.data(using: .ascii), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        if let outputImage = filter.outputImage {
            let transform = CGAffineTransform(scaleX: 8, y: 8)
            let scaledImage = outputImage.transformed(by: transform)
            let context = CIContext()
            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                self.qrImage = UIImage(cgImage: cgImage)
            }
        }
    }

    private func exportPhotosToDocuments(items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let movie = try? await item.loadTransferable(type: MovieTransferable.self) {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let dest = docs.appendingPathComponent(movie.url.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: movie.url, to: dest)
                }
            }
            await MainActor.run {
                self.selectedPhotosItems.removeAll()
                self.server.refreshSharedFiles()
            }
        }
    }
}
