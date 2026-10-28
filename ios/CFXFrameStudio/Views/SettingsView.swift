import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storage = StorageManager.shared

    @State private var showConfirmWipeAll: Bool = false
    @State private var showConfirmDeleteDocs: Bool = false
    @State private var showConfirmDeletePhotos: Bool = false
    @State private var includePhotosInMasterWipe: Bool = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.voidCanvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Total Storage Overview Card
                        totalStorageCard

                        // Detailed Storage Breakdown
                        breakdownCard

                        // Cleanup Actions Section
                        actionsSection

                        // App Version & Info
                        aboutSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }

                // In-progress overlay
                if storage.isClearing {
                    ZStack {
                        Color.black.opacity(0.7).ignoresSafeArea()
                        GlassCard(cornerRadius: 18, padding: 20) {
                            VStack(spacing: 14) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                                    .scaleEffect(1.4)
                                Text("Clearing Storage...")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.textPrimary)
                            }
                            .frame(maxWidth: 220)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("Storage & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.brandAccent)
                }
            }
            .alert("Delete All Downloads?", isPresented: $showConfirmDeleteDocs) {
                Button("Delete Files", role: .destructive) {
                    Task { _ = await storage.clearDownloadedFiles() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove all downloaded videos, remuxed files, and exports stored in 'On My iPhone > CFX Studio'.")
            }
            .alert("Delete Media from Camera Roll?", isPresented: $showConfirmDeletePhotos) {
                Button("Delete from Photos", role: .destructive) {
                    Task { _ = await storage.deleteAppMediaFromPhotos() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("iOS will prompt you to confirm removing the \(storage.breakdown.trackedPhotosCount) video(s) and photo(s) saved to your Photos library by CFX Studio.")
            }
            .alert("Master Wipe: Clear All Storage?", isPresented: $showConfirmWipeAll) {
                Button("Wipe Everything (Downloads, Files & Photos)", role: .destructive) {
                    Task { _ = await storage.masterWipeStorage(includePhotos: true) }
                }
                Button("Wipe Downloads & Cache Only", role: .destructive) {
                    Task { _ = await storage.masterWipeStorage(includePhotos: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all downloaded videos, remux caches, temporary files, and optionally removes saved media from Photos. Nothing downloaded will remain on the device.")
            }
            .onAppear {
                storage.refreshStorage()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Total Storage Card

    private var totalStorageCard: some View {
        GlassCard(cornerRadius: 18, padding: 18) {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient.brandGradient)
                            .frame(width: 48, height: 48)
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("App Storage Used")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.textMuted)

                        Text(storage.formatBytes(storage.breakdown.totalBytes))
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundColor(.textPrimary)
                    }

                    Spacer()

                    Button(action: { storage.refreshStorage() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.textSecondary)
                            .padding(10)
                            .background(Color.elevatedSurface)
                            .clipShape(Circle())
                    }
                }

                if let message = storage.lastReclaimedMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.emeraldAccent)
                            .font(.system(size: 13))
                        Text(message)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.emeraldAccent)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.emeraldAccent.opacity(0.12))
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Breakdown Card

    private var breakdownCard: some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("STORAGE BREAKDOWN")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.textTertiary)
                    .tracking(1.0)

                // Documents
                breakdownRow(
                    icon: "folder.fill",
                    color: .skyAccent,
                    title: "Downloaded Files & Exports",
                    subtitle: "On My iPhone > CFX Studio (\(storage.breakdown.documentsCount) files)",
                    value: storage.formatBytes(storage.breakdown.documentsBytes)
                )

                Divider().background(Color.borderHairline)

                // Temporary cache
                breakdownRow(
                    icon: "bolt.horizontal.fill",
                    color: .amberAccent,
                    title: "Temporary Cache & Remux Staging",
                    subtitle: "MKV remuxing, download chunks, trim buffers (\(storage.breakdown.tempCount) files)",
                    value: storage.formatBytes(storage.breakdown.tempBytes)
                )

                Divider().background(Color.borderHairline)

                // App caches
                breakdownRow(
                    icon: "globe",
                    color: .brandAccent,
                    title: "App & Playback Buffers",
                    subtitle: "URLSession network cache & AVPlayer playback data",
                    value: storage.formatBytes(storage.breakdown.cacheBytes)
                )

                Divider().background(Color.borderHairline)

                // Tracked photos
                breakdownRow(
                    icon: "photo.stack.fill",
                    color: .emeraldAccent,
                    title: "Saved Camera Roll Media",
                    subtitle: "Videos & photos saved to Photos app by CFX Studio",
                    value: "\(storage.breakdown.trackedPhotosCount) items"
                )
            }
        }
    }

    private func breakdownRow(icon: String, color: Color, title: String, subtitle: String, value: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.textPrimary)
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 10) {
            // Action 1: Clear All Cache & Downloaded Files
            Button(action: {
                Task { _ = await storage.clearAllCacheAndDownloads() }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                    Text("Clear Cache & Downloaded Files")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("Free \(storage.formatBytes(storage.breakdown.totalBytes))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.skyAccent)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 14)
                .background(Color.elevatedSurface)
                .foregroundColor(.skyAccent)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.skyAccent.opacity(0.3), lineWidth: 1)
                )
            }

            // Action 2: Delete Downloaded Files
            Button(action: { showConfirmDeleteDocs = true }) {
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .bold))
                    Text("Delete All Downloaded Files")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("Delete \(storage.formatBytes(storage.breakdown.documentsBytes))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.amberAccent)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 14)
                .background(Color.elevatedSurface)
                .foregroundColor(.amberAccent)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.amberAccent.opacity(0.3), lineWidth: 1)
                )
            }

            // Action 3: Delete App Media from Camera Roll
            if storage.breakdown.trackedPhotosCount > 0 {
                Button(action: { showConfirmDeletePhotos = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.badge.minus")
                            .font(.system(size: 14, weight: .bold))
                        Text("Delete App Media from Camera Roll")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Text("\(storage.breakdown.trackedPhotosCount) items")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.emeraldAccent)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .padding(.horizontal, 14)
                    .background(Color.elevatedSurface)
                    .foregroundColor(.emeraldAccent)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.emeraldAccent.opacity(0.3), lineWidth: 1)
                    )
                }
            }

            // Action 4: Master Wipe
            Button(action: { showConfirmWipeAll = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text("Master Clear Storage (Wipe Everything)")
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "FF4757"), Color(hex: "E84118")],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(12)
                .shadow(color: Color(hex: "FF4757").opacity(0.3), radius: 8, y: 3)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        GlassCard(cornerRadius: 14, padding: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CFX FrameStudio iOS")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text("Lossless Video Processing Engine • FFmpegKit Powered")
                        .font(.system(size: 10))
                        .foregroundColor(.textMuted)
                }
                Spacer()
                Text("v1.0")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.elevatedSurface)
                    .cornerRadius(6)
            }
        }
    }
}
