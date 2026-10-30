import SwiftUI

// MARK: - Tactile Spring Button Style
struct BentoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - Bento Grid Launcher View
struct LauncherView: View {
    @State private var showSettings: Bool = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.voidCanvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top App Header
                    headerBar

                    // Bento Grid Scroll View
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            // 1. Hero Featured Tool: Pro Video Editor (Full Width)
                            NavigationLink(destination: ProjectGalleryView()) {
                                heroBentoCard(
                                    title: "Pro Video Editor",
                                    badge: "MULTI-CLIP • TIMELINE",
                                    icon: "film.stack.fill",
                                    accentColor: .brandAccent,
                                    gradient: LinearGradient.brandGradient,
                                    footerTag: "OPTICAL FLOW • SPLIT • 4K EXPORT"
                                )
                            }
                            .buttonStyle(BentoButtonStyle())

                            // 2-Column Grid (10 Core Tools)
                            LazyVGrid(columns: columns, spacing: 12) {
                                // 1. Universal Downloader (Instagram, TikTok, Twitter/X, YouTube, Direct)
                                NavigationLink(destination: DirectDownloaderView()) {
                                    bentoCard(
                                        title: "Downloader",
                                        badge: "INSTA • TIKTOK • X • YT",
                                        icon: "arrow.down.circle",
                                        accentColor: .pinkAccent,
                                        footerTag: "HD VIDEO • REELS • AUDIO"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 2. VLC Pro Universal Player
                                NavigationLink(destination: UniversalPlayerView()) {
                                    bentoCard(
                                        title: "VLC Pro Player",
                                        badge: "ALL CODECS",
                                        icon: "play.tv.fill",
                                        accentColor: Color(hex: "FF8800"),
                                        footerTag: "SWIPE HUD • 200% BOOST"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 3. Video Trimmer
                                NavigationLink(destination: VideoTrimmerView()) {
                                    bentoCard(
                                        title: "Video Trimmer",
                                        badge: "0% LOSS",
                                        icon: "scissors",
                                        accentColor: .brandAccent,
                                        footerTag: "KEYFRAME COPY"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 4. Frame Exporter (Single Frame)
                                NavigationLink(destination: FrameExporterView()) {
                                    bentoCard(
                                        title: "Frame Exporter",
                                        badge: "1-FRAME",
                                        icon: "photo.stack",
                                        accentColor: .skyAccent,
                                        footerTag: "LOSSLESS PNG"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 5. Video Stitcher
                                NavigationLink(destination: VideoStitcherView()) {
                                    bentoCard(
                                        title: "Clip Stitcher",
                                        badge: "0% LOSS",
                                        icon: "film.stack",
                                        accentColor: .brandAccent,
                                        footerTag: "MERGE CLIPS"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 6. Sequence Exporter (Batch Frames)
                                NavigationLink(destination: FrameSequenceView()) {
                                    bentoCard(
                                        title: "Sequence Studio",
                                        badge: "VFX 60 FPS",
                                        icon: "film",
                                        accentColor: .skyAccent,
                                        gradient: LinearGradient(
                                            colors: [Color(hex: "00B4DB"), Color(hex: "0083B0")],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        footerTag: "BATCH PNG / ZIP"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 7. Audio Extractor
                                NavigationLink(destination: AudioExtractorView()) {
                                    bentoCard(
                                        title: "Audio Extractor",
                                        badge: "0% LOSS",
                                        icon: "waveform",
                                        accentColor: .brandAccent,
                                        gradient: LinearGradient.brandGradient,
                                        footerTag: "RIP M4A • MP3"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 8. Format Converter
                                NavigationLink(destination: VideoConverterView()) {
                                    bentoCard(
                                        title: "Converter",
                                        badge: "MKV • MP4",
                                        icon: "arrow.triangle.2.circlepath",
                                        accentColor: .emeraldAccent,
                                        footerTag: "100% QUALITY"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 9. Slow-Mo Studio
                                NavigationLink(destination: SlowMoView()) {
                                    bentoCard(
                                        title: "Slow-Mo Studio",
                                        badge: "OPTICAL FLOW",
                                        icon: "gauge.with.dots.needle.bottom.0percent",
                                        accentColor: .brandAccent,
                                        gradient: LinearGradient(
                                            colors: [Color(hex: "8A2387"), Color(hex: "E94057"), Color(hex: "F27121")],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        footerTag: "NEURAL RETIME"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // 10. Image Cropper
                                NavigationLink(destination: ImageCropperView()) {
                                    bentoCard(
                                        title: "Image Cropper",
                                        badge: "PRESETS",
                                        icon: "crop",
                                        accentColor: .amberAccent,
                                        footerTag: "PIXEL ACCURATE"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())
                            }

                            // System Telemetry Bento Bar (Full Width)
                            systemStatusCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.brandAccent)
                        .frame(width: 8, height: 8)
                        .shadow(color: Color.brandAccent.opacity(0.8), radius: 6)

                    Text("CFX FRAME STUDIO")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundColor(.textPrimary)
                        .tracking(1.0)
                }

                Text("Lossless Video & Frame Engine")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(Color.elevatedSurface)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.borderHairlineBright, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Hero Full-Width Bento Card
    private func heroBentoCard(
        title: String,
        badge: String,
        icon: String,
        accentColor: Color,
        gradient: LinearGradient? = nil,
        footerTag: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)

            HStack(spacing: 14) {
                ZStack {
                    if let grad = gradient {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(grad)
                            .frame(width: 44, height: 44)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accentColor.opacity(0.14))
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(accentColor.opacity(0.3), lineWidth: 1)
                            )
                    }

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(gradient == nil ? accentColor : .white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Spacer()

                        Text(badge)
                            .font(.system(size: 8.5, weight: .heavy))
                            .tracking(0.5)
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    HStack {
                        Text(footerTag)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.textTertiary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textTertiary)
                    }
                }
            }
            .padding(14)
        }
        .frame(height: 76)
    }

    // MARK: - Bento 2-Column Card (Clean - Subtexts Removed)
    private func bentoCard(
        title: String,
        badge: String,
        icon: String,
        accentColor: Color,
        gradient: LinearGradient? = nil,
        footerTag: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 0) {
                // Top Row: Icon + Badge
                HStack(alignment: .center) {
                    ZStack {
                        if let grad = gradient {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(grad)
                                .frame(width: 38, height: 38)
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(accentColor.opacity(0.14))
                                .frame(width: 38, height: 38)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(accentColor.opacity(0.3), lineWidth: 1)
                                )
                        }

                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(gradient == nil ? accentColor : .white)
                    }

                    Spacer()

                    Text(badge)
                        .font(.system(size: 8, weight: .heavy))
                        .tracking(0.5)
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                // Bold Clean Title
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer().frame(height: 8)

                // Bottom Tag + Arrow
                HStack(alignment: .center) {
                    Text(footerTag)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.textTertiary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.textTertiary)
                }
            }
            .padding(13)
        }
        .frame(height: 120)
    }

    // MARK: - System Status Bento Bar
    private var systemStatusCard: some View {
        GlassCard(cornerRadius: 16, padding: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.emeraldAccent)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.emeraldAccent.opacity(0.8), radius: 4)

                Text("METAL GPU ACCELERATED")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .tracking(0.6)

                Spacer()

                Text("AVFoundation • FFmpeg LGPL")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.textTertiary)
            }
        }
    }
}
