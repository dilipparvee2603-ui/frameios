import SwiftUI

struct LauncherView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.voidCanvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        // Header Branding
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.brandAccent)
                                    .frame(width: 9, height: 9)
                                    .shadow(color: Color.brandAccent.opacity(0.8), radius: 6)
                                Text("CFX FRAME STUDIO")
                                    .font(.system(size: 21, weight: .black, design: .rounded))
                                    .foregroundColor(.textPrimary)
                                    .tracking(1.5)
                            }

                            Text("Professional Video & Lossless Frame Engine for iOS")
                                .font(.system(size: 13))
                                .foregroundColor(.textMuted)

                            // Hardware Acceleration Chips
                            HStack(spacing: 8) {
                                statusChip(icon: "bolt.fill", text: "Metal GPU", color: .brandAccent)
                                statusChip(icon: "checkmark.seal.fill", text: "100% Lossless", color: .emeraldAccent)
                                statusChip(icon: "cpu.fill", text: "Hardware Decoder", color: .skyAccent)
                            }
                            .padding(.top, 4)
                        }
                        .padding(.top, 24)

                        // Studio Tools Section Header
                        HStack {
                            Text("STUDIO WORKSPACE")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.textTertiary)
                                .tracking(1.2)
                            Spacer()
                            Text("3 Tools Available")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.textMuted)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 6)

                        // Tool Cards
                        VStack(spacing: 14) {
                            // Video Trimmer Card
                            NavigationLink(destination: VideoTrimmerView()) {
                                toolCard(
                                    title: "Lossless Video Trimmer",
                                    subtitle: "Instant 0-second cut with zero re-encoding. Includes audio track muting.",
                                    icon: "scissors",
                                    gradient: LinearGradient.brandGradient,
                                    badges: ["⚡ Instant Cut", "🔇 Audio Mute"]
                                )
                            }

                            // Frame Exporter Card
                            NavigationLink(destination: FrameExporterView()) {
                                toolCard(
                                    title: "Precise Frame Exporter",
                                    subtitle: "Exact uncompressed frame stepping (1f / 10f). Export full-resolution PNG & JPG.",
                                    icon: "photo.stack",
                                    iconColor: .skyAccent,
                                    badges: ["🎯 1f / 10f Step", "📸 Lossless PNG"]
                                )
                            }

                            // Video Format Converter Card
                            NavigationLink(destination: VideoConverterView()) {
                                toolCard(
                                    title: "Video Format Converter",
                                    subtitle: "Convert MP4 ↔ MOV, MKV, ProRes at 100% original resolution with auto codec detection.",
                                    icon: "arrow.triangle.2.circlepath",
                                    iconColor: .emeraldAccent,
                                    badges: ["🔄 MP4 ↔ MOV", "💎 Zero Downscale"]
                                )
                            }
                        }
                        .padding(.horizontal, 20)

                        // Engine Performance Guarantee Card
                        GlassCard(cornerRadius: 14, padding: 14) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.emeraldAccent.opacity(0.12))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "shield.checkerboard")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundColor(.emeraldAccent)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Zero Cloud Uploads • 100% On-Device")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.textPrimary)
                                    Text("All video processing runs locally on your iPhone's Apple Silicon GPU.")
                                        .font(.system(size: 11))
                                        .foregroundColor(.textMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                        // Footer
                        VStack(spacing: 4) {
                            Text("CFX FrameStudio iOS • v1.2.0")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.textMuted)
                            Text("Powered by Apple AVFoundation & VideoToolbox")
                                .font(.system(size: 10))
                                .foregroundColor(.textTertiary)
                        }
                        .padding(.vertical, 16)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Helper Views

    private func statusChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }

    private func toolCard(
        title: String,
        subtitle: String,
        icon: String,
        gradient: LinearGradient? = nil,
        iconColor: Color = .white,
        badges: [String] = []
    ) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            HStack(alignment: .top, spacing: 14) {
                // Icon Block
                ZStack {
                    if let grad = gradient {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(grad)
                            .frame(width: 50, height: 50)
                    } else {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.elevatedSurface)
                            .frame(width: 50, height: 50)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(iconColor.opacity(0.4), lineWidth: 1)
                            )
                    }
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(iconColor)
                }

                // Text Content
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.textMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // Tag Pills
                    if !badges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(badges, id: \.self) { badge in
                                Text(badge)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.textMuted)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.elevatedSurface)
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.textTertiary)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 16)
            }
        }
    }
}
