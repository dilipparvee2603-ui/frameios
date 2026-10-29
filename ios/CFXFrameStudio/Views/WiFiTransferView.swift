import SwiftUI
import PhotosUI
import CoreImage
import WebKit

// MARK: - Wi-Fi Sync Mode Enum
enum WiFiSyncMode: String, CaseIterable, Identifiable {
    case webDrop = "WebDrop P2P"
    case localServer = "Local IP Server"
    
    var id: String { rawValue }
}

// MARK: - Wi-Fi Transfer View
struct WiFiTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var server = WiFiTransferServer.shared

    @State private var selectedMode: WiFiSyncMode = .webDrop
    @State private var showPhotosPicker: Bool = false
    @State private var showWebDropRadarSheet: Bool = false
    @State private var selectedPhotosItems: [PhotosPickerItem] = []
    @State private var copiedToast: Bool = false
    @State private var copiedToastMessage: String = "Link Copied to Clipboard!"
    @State private var qrImage: UIImage? = nil

    private let webDropURLString = "https://pairdrop.net"

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                navigationHeader

                // Mode Segmented Switcher
                modeSelectorBar

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if selectedMode == .webDrop {
                            // P2P WebDrop Section (Default & Recommended)
                            webDropSection
                        } else {
                            // Local IP Server Section (For Hotspot / Open LAN)
                            localServerSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
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
        .sheet(isPresented: $showWebDropRadarSheet) {
            WebDropSheetView()
        }
        .onAppear {
            updateQrCode()
        }
        .onChange(of: selectedMode) { _ in
            updateQrCode()
        }
        .onChange(of: server.localIP) { _ in
            if selectedMode == .localServer {
                updateQrCode()
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
                    Text("WI-FI PC SYNC")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(selectedMode == .webDrop ? "P2P WEBRTC" : (server.isRunning ? "ONLINE" : "OFFLINE"))
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundColor(selectedMode == .webDrop || server.isRunning ? .emeraldAccent : .textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background((selectedMode == .webDrop || server.isRunning ? Color.emeraldAccent : Color.textTertiary).opacity(0.14))
                        .clipShape(Capsule())
                }

                Text("Fast Wireless Transfer Between iPhone & Windows PC")
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            if selectedMode == .localServer {
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
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Mode Selector Bar
    private var modeSelectorBar: some View {
        HStack(spacing: 6) {
            ForEach(WiFiSyncMode.allCases) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedMode = mode
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: mode == .webDrop ? "sparkles" : "network")
                            .font(.system(size: 11, weight: .bold))
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: .bold))
                        if mode == .webDrop {
                            Text("FAST")
                                .font(.system(size: 8, weight: .heavy))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.emeraldAccent.opacity(0.25))
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundColor(selectedMode == mode ? .white : .textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        selectedMode == mode ? Color.brandAccent.opacity(0.85) : Color.elevatedSurface
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selectedMode == mode ? Color.brandAccent : Color.borderHairline, lineWidth: 1)
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - WebDrop P2P Section
    private var webDropSection: some View {
        VStack(spacing: 16) {
            // Hero Status Card
            GlassCard(cornerRadius: 18, padding: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.emeraldAccent.opacity(0.14))
                            .frame(width: 48, height: 48)

                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.emeraldAccent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("WebDrop P2P Ready")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Text("Bypasses Router AP Isolation • Up to 80 MB/s")
                            .font(.system(size: 11))
                            .foregroundColor(.emeraldAccent)
                    }

                    Spacer()
                }
            }

            // Quick How-To Steps Card
            GlassCard(cornerRadius: 18, padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("HOW TO CONNECT IN 30 SECONDS")
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundColor(.skyAccent)
                            .tracking(0.8)

                        Spacer()

                        Text("ZERO SETUP")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundColor(.emeraldAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.emeraldAccent.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        instructionStep(
                            num: "1",
                            title: "Open on PC Browser",
                            detail: "On your Windows PC (Chrome, Edge, or Brave), visit pairdrop.net"
                        )

                        instructionStep(
                            num: "2",
                            title: "Launch WebDrop Radar Below",
                            detail: "Tap the button below. Both devices will appear on radar instantly!"
                        )

                        instructionStep(
                            num: "3",
                            title: "Tap Device & Send Videos",
                            detail: "Tap your PC on the radar screen to send 4K clips, or drop files on PC to receive."
                        )
                    }
                }
            }

            // Launch WebDrop Radar Button (Primary Call To Action)
            Button(action: {
                showWebDropRadarSheet = true
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "radar")
                        .font(.system(size: 17, weight: .bold))

                    Text("Launch In-App WebDrop Radar")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color.brandAccent, Color(hex: "00B4DB")],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.brandAccent.opacity(0.35), radius: 10, y: 4)
            }

            // QR Code & PC URL Card
            GlassCard(cornerRadius: 20, padding: 20) {
                VStack(spacing: 14) {
                    Text("PC BROWSER ACCESS LINK")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(.skyAccent)
                        .tracking(0.8)

                    // URL Pill
                    HStack(spacing: 8) {
                        Text(webDropURLString)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.textPrimary)

                        Spacer()

                        Button(action: {
                            UIPasteboard.general.string = webDropURLString
                            triggerToast(message: "pairdrop.net copied to clipboard!")
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

                            Text("Scan with your PC / Laptop camera to open")
                                .font(.system(size: 10.5))
                                .foregroundColor(.textTertiary)
                        }
                    }

                    // Open in Safari Option
                    Button(action: {
                        if let url = URL(string: webDropURLString) {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                                .font(.system(size: 12, weight: .bold))
                            Text("Or open in Mobile Safari")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.textSecondary)
                        .padding(.top, 4)
                    }
                }
            }

            // Benefits Grid Card
            GlassCard(cornerRadius: 16, padding: 14) {
                VStack(spacing: 12) {
                    benefitRow(
                        icon: "bolt.fill",
                        color: .amberAccent,
                        title: "Full Local Wi-Fi Speeds",
                        subtitle: "35 – 80 MB/s direct P2P data streaming."
                    )

                    Divider().background(Color.borderHairline)

                    benefitRow(
                        icon: "lock.shield.fill",
                        color: .emeraldAccent,
                        title: "End-to-End Encrypted",
                        subtitle: "P2P WebRTC data channels — 0 MB internet quota used."
                    )

                    Divider().background(Color.borderHairline)

                    benefitRow(
                        icon: "checkmark.seal.fill",
                        color: .skyAccent,
                        title: "100% Lossless Video Transfer",
                        subtitle: "Preserves original 4K/HDR bitrates & metadata."
                    )
                }
            }
        }
    }

    private func instructionStep(num: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(num)
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Color.brandAccent)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
                    .lineSpacing(2)
            }
        }
    }

    private func benefitRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(color)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(.textMuted)
            }
            Spacer()
        }
    }

    // MARK: - Local Server Section
    private var localServerSection: some View {
        VStack(spacing: 16) {
            // Notice about AP Isolation
            GlassCard(cornerRadius: 14, padding: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.skyAccent)

                    Text("Best used when connected via iPhone Personal Hotspot or open local networks without router AP isolation.")
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                }
            }

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
    }

    // MARK: - Local Server Components
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
                        triggerToast(message: "Server URL copied!")
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

                        Text("Scan QR code with your laptop / tablet camera")
                            .font(.system(size: 10.5))
                            .foregroundColor(.textTertiary)
                    }
                }
            }
        }
    }

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

    private var offlineGuideCard: some View {
        GlassCard(cornerRadius: 18, padding: 20) {
            VStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 32))
                    .foregroundColor(.textTertiary)

                VStack(spacing: 6) {
                    Text("How Local Server Mode Works")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text("1. Turn on iPhone Personal Hotspot or join an open local Wi-Fi.\n2. Tap 'Start' to activate the local web server.\n3. Type the generated IP address into your PC browser (Chrome/Edge).\n4. Drag-and-drop 4K files, download trimmed clips, or send MKVs wirelessly.")
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
                Text(copiedToastMessage)
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

    private func triggerToast(message: String) {
        copiedToastMessage = message
        withAnimation { copiedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copiedToast = false }
        }
    }

    // MARK: - Helpers
    private func updateQrCode() {
        let textToEncode: String
        if selectedMode == .webDrop {
            textToEncode = webDropURLString
        } else {
            guard let url = server.serverUrlString else {
                qrImage = nil
                return
            }
            textToEncode = url
        }
        qrImage = generateQRCode(from: textToEncode)
    }

    private func generateQRCode(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 8, y: 8)
        let scaledImage = outputImage.transformed(by: transform)
        let context = CIContext()
        if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        return nil
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

// MARK: - In-App WebDrop Radar Sheet
struct WebDropSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading: Bool = true
    @State private var reloadToken: UUID = UUID()

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header Bar
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("WEBDROP P2P RADAR")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.textPrimary)

                            Text("LIVE")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundColor(.emeraldAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.emeraldAccent.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        Text("Tap PC icon to send clips losslessly")
                            .font(.system(size: 10.5))
                            .foregroundColor(.textMuted)
                    }

                    Spacer()

                    // Reload Button
                    Button(action: {
                        reloadToken = UUID()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(Color.elevatedSurface)
                            .clipShape(Circle())
                    }

                    // Open Safari
                    Button(action: {
                        if let url = URL(string: "https://pairdrop.net") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Image(systemName: "safari")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.skyAccent)
                            .frame(width: 34, height: 34)
                            .background(Color.elevatedSurface)
                            .clipShape(Circle())
                    }

                    // Close Button
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Color.elevatedSurface)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.surfaceCard)

                Divider().background(Color.borderHairline)

                // Embedded WebRTC Web Drop View
                ZStack {
                    WebDropWebView(url: URL(string: "https://pairdrop.net")!, isLoading: $isLoading)
                        .id(reloadToken)

                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(Color.emeraldAccent)
                            Text("Connecting WebRTC P2P Radar...")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.voidCanvas)
                    }
                }
            }
        }
    }
}

// MARK: - WebDrop Web View (UIViewRepresentable)
struct WebDropWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 10/255, green: 11/255, blue: 14/255, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 10/255, green: 11/255, blue: 14/255, alpha: 1.0)
        webView.scrollView.bounces = true

        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebDropWebView

        init(_ parent: WebDropWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }
    }
}
