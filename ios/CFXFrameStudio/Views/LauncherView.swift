import SwiftUI

struct LauncherView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.voidCanvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header Branding
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.brandAccent)
                                .frame(width: 8, height: 8)
                            Text("CFX FRAME STUDIO")
                                .font(.system(size: 20, weight: .black, design: .rounded))
                                .foregroundColor(.textPrimary)
                                .tracking(1.5)
                        }

                        Text("Lossless Video & Frame Precision Engine")
                            .font(.system(size: 13))
                            .foregroundColor(.textMuted)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                    // 4 Clean Tool Cards
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            NavigationLink(destination: VideoTrimmerView()) {
                                toolCard(
                                    title: "Lossless Video Trimmer",
                                    subtitle: "Instant stream-copy cut with optional audio muting",
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
                                    subtitle: "Convert MP4 ↔ MOV at 100% original resolution",
                                    icon: "arrow.triangle.2.circlepath",
                                    accentColor: .emeraldAccent
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
                    Text("Powered by Apple AVFoundation & Metal")
                        .font(.system(size: 11))
                        .foregroundColor(.textTertiary)
                        .padding(.bottom, 24)
                }
            }
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
