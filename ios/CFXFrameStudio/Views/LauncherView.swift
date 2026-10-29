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

                // Ambient Background Glow
                ambientGlow

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

                            // 2. Bento 2-Column Grid of Core Tools
                            LazyVGrid(columns: columns, spacing: 12) {
                                // Lossless Trimmer
                                NavigationLink(destination: VideoTrimmerView()) {
                                    bentoCard(
                                        title: "Video Trimmer",
                                        subtitle: "Lossless stream-copy cut for MP4, MOV & MKV",
                                        badge: "0% LOSS",
                                        icon: "scissors",
                                        accentColor: .brandAccent,
                                        footerTag: "INSTANT CUT"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // Frame Exporter
                                NavigationLink(destination: FrameExporterView()) {
                                    bentoCard(
                                        title: "Frame Exporter",
                                        subtitle: "Sub-frame precision PNG extract & crop",
                                        badge: "1-FRAME STEP",
                                        icon: "photo.stack",
                                        accentColor: .skyAccent,
                                        footerTag: "UNCOMPRESSED"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // Format Converter
                                NavigationLink(destination: VideoConverterView()) {
                                    bentoCard(
                                        title: "Format Converter",
                                        subtitle: "MKV ↔ MP4 ↔ MOV with full audio copy",
                                        badge: "MULTI-FORMAT",
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
                                        subtitle: "Optical flow frame synthesis down to 10%",
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
                                        subtitle: "1:1, 4:5, 16:9, 9:16 & custom ratios",
                                        badge: "ASPECT RATIOS",
                                        icon: "crop",
                                        accentColor: .amberAccent,
                                        footerTag: "PIXEL PERFECT"
                                    )
                                }
                                .buttonStyle(BentoButtonStyle())

                                // Direct Downloader
                                NavigationLink(destination: DirectDownloaderView()) {
                                    bentoCard(
                                        title: "Link Downloader",
                                        subtitle: "Direct Cloudflare & CDN video fetch",
                                        badge: "FAST FETCH",
                                        icon: "arrow.down.circle",
                                        accentColor: .skyAccent,
                                        footerTag: "STREAM CAPTURE"
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
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Hero Bento Card (Studio Video Enhancer)
    private var heroEnhancerCard: some View {
        ZStack(alignment: .topTrailing) {
            // Glass container
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
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
                .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 14) {
                // Top row with Icon, Badge, and Action Pill
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "00B4DB"), Color(hex: "8A2387")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 46, height: 46)
                            .shadow(color: Color(hex: "00B4DB").opacity(0.4), radius: 8)

                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("STUDIO FLAGSHIP")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(1.0)
                                .foregroundColor(Color(hex: "38BDF8"))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(hex: "38BDF8").opacity(0.14))
                                .clipShape(Capsule())

                            Text("PRO AI")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(Color.pinkAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.pinkAccent.opacity(0.14))
                                .clipShape(Capsule())
                        }

                        Text("AI Video Enhancer")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.textPrimary)
                    }

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }

                // Subtitle description
                Text("AirVid portrait skin retouch, AMD CAS texture sharpening & 4K super-resolution reconstruction")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // Feature pills
                HStack(spacing: 6) {
                    featurePill(title: "✨ AirVid Face", color: .pinkAccent)
                    featurePill(title: "🔍 CAS Sharpen", color: .brandAccent)
                    featurePill(title: "🚀 4K UHD", color: .skyAccent)
                    featurePill(title: "🧹 De-noise", color: .emeraldAccent)
                }
            }
            .padding(18)
        }
    }

    private func featurePill(title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color.opacity(0.25), lineWidth: 0.8)
            )
    }

    // MARK: - Bento 2-Column Card
    private func bentoCard(
        title: String,
        subtitle: String,
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
                .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 10) {
                // Top Row: Icon + Badge
                HStack(alignment: .top) {
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
                            .font(.system(size: 18, weight: .bold))
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

                // Title & Subtitle
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 28, alignment: .topLeading)
                }

                Spacer(minLength: 0)

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
        .frame(minHeight: 148)
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

    // MARK: - Subtle Ambient Glow
    private var ambientGlow: some View {
        VStack {
            HStack {
                Circle()
                    .fill(Color.brandAccent.opacity(0.08))
                    .frame(width: 250, height: 250)
                    .blur(radius: 60)
                    .offset(x: -80, y: -60)
                Spacer()
                Circle()
                    .fill(Color(hex: "00B4DB").opacity(0.06))
                    .frame(width: 220, height: 220)
                    .blur(radius: 60)
                    .offset(x: 60, y: -40)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
