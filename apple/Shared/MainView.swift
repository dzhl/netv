import SwiftUI

struct MainView: View {
    var body: some View {
        #if os(tvOS)
        TabView {
            WatchView()
                .tabItem { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        #elseif os(macOS)
        MacMainView()
        #else
        TabView {
            NavigationStack {
                WatchView()
            }
            .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        #endif
    }
}

#if os(macOS)
private enum MacDestination: String, CaseIterable, Identifiable {
    case live
    case settings

    var id: Self { self }
    var title: String { self == .live ? "Live TV" : "Settings" }
    var icon: String { self == .live ? "dot.radiowaves.left.and.right" : "gearshape.fill" }
}

private struct MacMainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var destination: MacDestination = .live

    var body: some View {
        Group {
            switch destination {
            case .live:
                WatchView()
            case .settings:
                SettingsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach(MacDestination.allCases) { item in
                        Button {
                            destination = item
                        } label: {
                            Label(item.title, systemImage: item.icon)
                        }
                    }
                } label: {
                    Label("Navigation", systemImage: "line.3.horizontal")
                }
                .help("Navigate neTV")
            }
            ToolbarItem(placement: .automatic) {
                TextField("Search channels and programs", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }
        }
        .toolbar(model.isPlayerExpanded ? .hidden : .automatic)
    }
}
#endif
