import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            if model.isCheckingSession {
                LaunchView()
            } else if model.isAuthenticated {
                MainView()
            } else {
                LoginView()
            }
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            BrandMark(size: 72)
            ProgressView()
                .tint(.white)
        }
    }
}

struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.accent, Color(red: 0.27, green: 0.76, blue: 1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.35), radius: size * 0.25, y: size * 0.1)
    }
}
