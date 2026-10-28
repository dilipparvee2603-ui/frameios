import SwiftUI

// MARK: - CFX Studio Glassmorphic Dark Tokens
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    static let voidCanvas = Color(hex: "0D0D11")
    static let surfaceCard = Color(hex: "15151A")
    static let elevatedSurface = Color(hex: "1A1A22")
    static let borderHairline = Color.white.opacity(0.08)
    static let borderHairlineBright = Color.white.opacity(0.16)
    static let cardBorder = Color.white.opacity(0.08)

    // Brand Crimson Accents
    static let brandAccent = Color(hex: "C0000A")
    static let brandVibrant = Color(hex: "E31B23")
    static let gradientStart = Color(hex: "FF4A3D")
    static let gradientEnd = Color(hex: "D92A20")

    // Status Accents
    static let emeraldAccent = Color(hex: "10B981")
    static let skyAccent = Color(hex: "38BDF8")
    static let amberAccent = Color(hex: "F59E0B")

    // Typography
    static let textPrimary = Color(hex: "F4F5F7")
    static let textSecondary = Color(hex: "CBD5E1")
    static let textMuted = Color(hex: "94A3B8")
    static let textTertiary = Color(hex: "64748B")
}

extension LinearGradient {
    static let brandGradient = LinearGradient(
        colors: [Color.gradientStart, Color.gradientEnd],
        startPoint: .leading,
        endPoint: .trailing
    )
}
