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
        HStack(spacing: 0) {
            if !model.isPlayerExpanded {
                navigationRail
            }
            Group {
                switch destination {
                case .live:
                    WatchView()
                case .settings:
                    SettingsView()
                }
            }
        }
        .background(MacGuideTheme.background)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(destination.title)
                    .font(.headline)
            }
            if destination == .live {
                ToolbarItem(placement: .automatic) {
                    TextField("Search channels and programs", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await model.loadGuide() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                    .help("Refresh guide")
                    .accessibilityLabel("Refresh guide")
                }
            }
        }
        .toolbar(model.isPlayerExpanded ? .hidden : .automatic)
    }

    private var navigationRail: some View {
        VStack(spacing: 18) {
            BrandMark(size: 34)
                .padding(.bottom, 10)
                .accessibilityLabel("neTV")
            ForEach(MacDestination.allCases) { item in
                if item == .settings {
                    Spacer()
                }
                Button {
                    destination = item
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 42, height: 44)
                }
                .buttonStyle(MacGuideButtonStyle(isSelected: destination == item))
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityValue(destination == item ? "Selected" : "")
            }
        }
        .padding(.vertical, 22)
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(MacGuideTheme.background)
        .overlay(alignment: .trailing) {
            MacGuideTheme.divider.frame(width: 1)
        }
    }
}
#endif
