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
                            // 1. Hero Bento Card: Studio Video Enhancer (Full Width)
                            NavigationLink(destination: VideoEnhancerView()) {
                                heroEnhancerCard
                            }
                            .buttonStyle(BentoButtonStyle())

                            // 2. Bento 2-Column Grid of Core Tools (Clean - Subtexts Removed)
                            LazyVGrid(columns: columns, spacing: 12) {
                                // Lossless Trimmer
                                NavigationLink(destination: VideoTrimmerView()) {
                                    bentoCard(
                                        title: "Video Trimmer",
                                        badge: "0% LOSS",
                                        icon: "scissors",
                                        accentColor: .brandAccent,
                                        footerTag: "STREAM COPY"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // Frame Exporter
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

                                // Format Converter
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

                                // Slow-Mo Studio
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

                                // Image Cropper
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

                                // Direct Downloader
                                NavigationLink(destination: DirectDownloaderView()) {
                                    bentoCard(
                                        title: "Downloader",
                                        badge: "FAST FETCH",
                                        icon: "arrow.down.circle",
                                        accentColor: .skyAccent,
                                        footerTag: "CDN CAPTURE"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())
                            }

                            // 3. System Telemetry Bento Bar (Full Width)
                            systemStatusCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(ambientGlow.clipped())
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
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(.textPrimary)
                        .tracking(1.2)
                }

                Text("Lossless Video & Remastering Engine")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Color.elevatedSurface)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.borderHairlineBright, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Hero Bento Card (Studio Video Enhancer)
    private var heroEnhancerCard: some View {
        ZStack(alignment: .topTrailing) {
            // Glass container
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "0F172A"),
                            Color(hex: "171923"),
                            Color.surfaceCard
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(hex: "00B4DB").opacity(0.4),
                                    Color(hex: "8A2387").opacity(0.2),
                                    Color.borderHairline
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 12) {
                // Top row with Icon, Badge, and Action Pill
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "00B4DB"), Color(hex: "8A2387")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                            .shadow(color: Color(hex: "00B4DB").opacity(0.35), radius: 6)

                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("STUDIO FLAGSHIP")
                                .font(.system(size: 8.5, weight: .heavy))
                                .tracking(0.8)
                                .foregroundColor(Color(hex: "38BDF8"))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(hex: "38BDF8").opacity(0.14))
                                .clipShape(Capsule())

                            Text("PRO AI")
                                .font(.system(size: 8.5, weight: .heavy))
                                .foregroundColor(Color.pinkAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.pinkAccent.opacity(0.14))
                                .clipShape(Capsule())
                        }

                        Text("AI Video Enhancer")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.textPrimary)
                    }

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }

                // Subtitle description (single clean line)
                Text("AirVid portrait retouch, CAS sharpening & 4K super-resolution")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(.textMuted)
                    .lineLimit(1)

                // Feature pills
                HStack(spacing: 6) {
                    featurePill(title: "✨ AirVid Face", color: .pinkAccent)
                    featurePill(title: "🔍 CAS Sharpen", color: .brandAccent)
                    featurePill(title: "🚀 4K UHD", color: .skyAccent)
                    featurePill(title: "🧹 De-noise", color: .emeraldAccent)
                }
            }
            .padding(16)
        }
    }

    private func featurePill(title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Color.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color.opacity(0.25), lineWidth: 0.8)
            )
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
                .shadow(color: Color.black.opacity(0.28), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 10) {
                // Top Row: Icon + Badge
                HStack(alignment: .center) {
                    ZStack {
                        if let grad = gradient {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(grad)
                                .frame(width: 40, height: 40)
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(accentColor.opacity(0.14))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(accentColor.opacity(0.3), lineWidth: 1)
                                )
                        }

                        Image(systemName: icon)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(gradient == nil ? accentColor : .white)
                    }

                    Spacer()

                    Text(badge)
                        .font(.system(size: 8, weight: .heavy))
                        .tracking(0.6)
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 4)

                // Bold Clean Title (No cramped subtext)
                Text(title)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                // Bottom Tag + Arrow
                HStack {
                    Text(footerTag)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.textTertiary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.textTertiary)
                }
            }
            .padding(14)
        }
        .frame(height: 124)
    }

    // MARK: - System Status Bento Bar
    private var systemStatusCard: some View {
        GlassCard(cornerRadius: 16, padding: 12) {
            HStack(spacing: 10) {
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

    // MARK: - Subtle Ambient Glow (Strictly bounded)
    private var ambientGlow: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color.brandAccent.opacity(0.07))
                    .frame(width: 200, height: 200)
                    .blur(radius: 50)
                    .position(x: 30, y: 30)

                Circle()
                    .fill(Color(hex: "00B4DB").opacity(0.06))
                    .frame(width: 200, height: 200)
                    .blur(radius: 50)
                    .position(x: geo.size.width - 30, y: 50)
            }
        }
        .allowsHitTesting(false)
    }
}
