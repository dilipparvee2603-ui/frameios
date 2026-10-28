import SwiftUI

struct LauncherView: View {
    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.voidCanvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header Branding & Settings Button
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.brandAccent)
                                    .frame(width: 8, height: 8)
                                Text("CFX FRAME STUDIO")
                                    .font(.system(size: 19, weight: .black, design: .rounded))
                                    .foregroundColor(.textPrimary)
                                    .tracking(1.2)
                            }

                            Text("Lossless Video & Frame Engine")
                                .font(.system(size: 12))
                                .foregroundColor(.textMuted)
                        }

                        Spacer()

                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.textSecondary)
                                .frame(width: 38, height: 38)
                                .background(Color.elevatedSurface)
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.borderHairline, lineWidth: 1)
                                )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                    // 4 Clean Tool Cards
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            NavigationLink(destination: VideoTrimmerView()) {
                                toolCard(
                                    title: "Lossless Video Trimmer",
                                    subtitle: "Instant stream-copy cut (MP4, MOV & Matroska MKV)",
                                    icon: "scissors",
                                    accentColor: .brandAccent,
                                    gradient: LinearGradient.brandGradient
                                )
                            }

                            NavigationLink(destination: FrameExporterView()) {
                                toolCard(
                                    title: "Precise Frame Exporter",
                                    subtitle: "1f & 10f hardware stepping to uncompressed PNG",
                                    icon: "photo.stack",
                                    accentColor: .skyAccent
                                )
                            }

                            NavigationLink(destination: VideoConverterView()) {
                                toolCard(
                                    title: "Video Format Converter",
                                    subtitle: "Convert MP4 ↔ MOV & Matroska MKV at 100% resolution",
                                    icon: "arrow.triangle.2.circlepath",
                                    accentColor: .emeraldAccent
                                )
                            }

                            NavigationLink(destination: SlowMoView()) {
                                toolCard(
                                    title: "Smooth Slow-Mo Studio",
                                    subtitle: "Optical flow motion synthesis & percentage retiming",
                                    icon: "gauge.with.dots.needle.bottom.0percent",
                                    accentColor: .brandAccent,
                                    gradient: LinearGradient(
                                        colors: [Color(hex: "8A2387"), Color(hex: "E94057"), Color(hex: "F27121")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            }

                            NavigationLink(destination: VideoEnhancerView()) {
                                toolCard(
                                    title: "Studio Video Enhancer",
                                    subtitle: "Topaz-grade multi-pass reconstruction, 4K upscale & de-noise",
                                    icon: "wand.and.stars",
                                    accentColor: .brandAccent,
                                    gradient: LinearGradient(
                                        colors: [Color(hex: "00B4DB"), Color(hex: "0083B0"), Color(hex: "8A2387")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            }

                            NavigationLink(destination: ImageCropperView()) {
                                toolCard(
                                    title: "Lossless Image Cropper",
                                    subtitle: "Crop to custom & social ratios (1:1, 4:5, 16:9, 9:16)",
                                    icon: "crop",
                                    accentColor: .amberAccent
                                )
                            }

                            NavigationLink(destination: DirectDownloaderView()) {
                                toolCard(
                                    title: "Direct Link Downloader",
                                    subtitle: "Download Cloudflare & CDN links with smart codec save",
                                    icon: "arrow.down.circle",
                                    accentColor: .skyAccent
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }

                    Spacer()

                    // Minimal Footer
                    Text("Powered by Apple AVFoundation, Metal & FFmpeg Engine")
                        .font(.system(size: 11))
                        .foregroundColor(.textTertiary)
                        .padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .preferredColorScheme(.dark)
    }

    private func toolCard(
        title: String,
        subtitle: String,
        icon: String,
        accentColor: Color,
        gradient: LinearGradient? = nil
    ) -> some View {
        GlassCard(cornerRadius: 18, padding: 20) {
            HStack(spacing: 16) {
                ZStack {
                    if let grad = gradient {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(grad)
                            .frame(width: 52, height: 52)
                    } else {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.elevatedSurface)
                            .frame(width: 52, height: 52)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(accentColor.opacity(0.35), lineWidth: 1)
                            )
                    }
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(gradient == nil ? accentColor : .white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.textMuted)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.textTertiary)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}
