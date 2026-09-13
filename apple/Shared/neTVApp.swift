import SwiftUI

@main
struct neTVApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 780)
        #else
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        #endif
    }
}
