import SwiftUI

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 16
    var borderColor: Color = Color.borderHairline
    let content: () -> Content

    init(
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 16,
        borderColor: Color = Color.borderHairline,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.borderColor = borderColor
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(Color.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
    }
}
