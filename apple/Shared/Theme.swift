import SwiftUI

enum Theme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.09)
    static let surface = Color(red: 0.075, green: 0.105, blue: 0.16)
    static let elevated = Color(red: 0.12, green: 0.16, blue: 0.23)
    static let accent = Color(red: 0.19, green: 0.48, blue: 0.98)
    static let live = Color(red: 1.0, green: 0.23, blue: 0.29)
    static let secondaryText = Color.white.opacity(0.62)

    static let backgroundGradient = LinearGradient(
        colors: [background, Color(red: 0.045, green: 0.08, blue: 0.14)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

#if os(macOS)
enum MacGuideTheme {
    static let background = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let sidebar = Color(red: 0.13, green: 0.15, blue: 0.18)
    static let surface = Color(red: 0.18, green: 0.20, blue: 0.24)
    static let selection = Color(red: 0.29, green: 0.33, blue: 0.38)
    static let program = Color(red: 0.57, green: 0.42, blue: 0.87)
    static let divider = Color.white.opacity(0.08)
}
#endif

struct GlassCard: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(Theme.surface.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

extension View {
    func glassCard(radius: CGFloat = 18) -> some View {
        modifier(GlassCard(radius: radius))
    }
}
