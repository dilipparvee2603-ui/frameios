import SwiftUI

struct LauncherView: View {
    @State private var navigateToTrimmer = false
    @State private var navigateToExporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.voidCanvas.ignoresSafeArea()

                VStack(spacing: 24) {
                    // Header Branding
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.brandAccent)
                                .frame(width: 10, height: 10)
                            Text("CFX FRAME STUDIO")
                                .font(.system(size: 20, weight: .black, design: .rounded))
                                .foregroundColor(.textPrimary)
                                .tracking(1.5)
                        }

                        Text("Professional Video & Lossless Frame Engine for iOS")
                            .font(.system(size: 13))
                            .foregroundColor(.textMuted)
                    }
                    .padding(.top, 40)

                    Spacer()

                    // Tool Cards
                    VStack(spacing: 16) {
                        // Video Trimmer Card
                        NavigationLink(destination: VideoTrimmerView()) {
                            GlassCard(cornerRadius: 18, padding: 20) {
                                HStack(spacing: 16) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(LinearGradient.brandGradient)
                                            .frame(width: 52, height: 52)
                                        Image(systemName: "scissors")
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundColor(.white)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Lossless Video Trimmer")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.textPrimary)
                                        Text("0-second stream copy cut with optional audio muting")
                                            .font(.system(size: 12))
                                            .foregroundColor(.textMuted)
                                            .multilineTextAlignment(.leading)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.textTertiary)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                        }

                        // Frame Exporter Card
                        NavigationLink(destination: FrameExporterView()) {
                            GlassCard(cornerRadius: 18, padding: 20) {
                                HStack(spacing: 16) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(Color.elevatedSurface)
                                            .frame(width: 52, height: 52)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .stroke(Color.skyAccent.opacity(0.4), lineWidth: 1)
                                            )
                                        Image(systemName: "photo.stack")
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundColor(.skyAccent)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Precise Frame Exporter")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.textPrimary)
                                        Text("Exact uncompressed frame stepping (1f / 10f) to PNG & JPG")
                                            .font(.system(size: 12))
                                            .foregroundColor(.textMuted)
                                            .multilineTextAlignment(.leading)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.textTertiary)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                        }

                        // Video Format Converter Card
                        NavigationLink(destination: VideoConverterView()) {
                            GlassCard(cornerRadius: 18, padding: 20) {
                                HStack(spacing: 16) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(Color.elevatedSurface)
                                            .frame(width: 52, height: 52)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .stroke(Color.emeraldAccent.opacity(0.4), lineWidth: 1)
                                            )
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundColor(.emeraldAccent)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Video Format Converter")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.textPrimary)
                                        Text("Convert MP4 ↔ MOV, MKV, ProRes at 100% original resolution")
                                            .font(.system(size: 12))
                                            .foregroundColor(.textMuted)
                                            .multilineTextAlignment(.leading)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.textTertiary)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer()

                    // Footer
                    Text("Powered by Apple AVFoundation & Metal GPU Acceleration")
                        .font(.system(size: 11))
                        .foregroundColor(.textTertiary)
                        .padding(.bottom, 20)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
