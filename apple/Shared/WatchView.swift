import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WatchView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        #if os(macOS)
        macLayout
        #else
        standardLayout
        #endif
    }

    #if os(macOS)
    private var macLayout: some View {
        GeometryReader { proxy in
            let heroHeight = min(proxy.size.height * 0.48, 430)
            ZStack(alignment: .topLeading) {
                if !model.isPlayerExpanded {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            MacHeroInfo(selection: model.selection)
                                .frame(width: proxy.size.width * 0.44, height: heroHeight)
                            Color.black
                                .frame(width: proxy.size.width * 0.56, height: heroHeight)
                        }
                        GuideView()
                            .frame(
                                width: proxy.size.width,
                                height: max(proxy.size.height - heroHeight, 0)
                            )
                    }
                    .transition(.opacity)
                }

                ZStack(alignment: .topTrailing) {
                    playerSurface
                    expandButton
                }
                .frame(
                    width: model.isPlayerExpanded ? proxy.size.width : proxy.size.width * 0.56,
                    height: model.isPlayerExpanded ? proxy.size.height : heroHeight
                )
                .background(.black)
                .clipped()
                .offset(x: model.isPlayerExpanded ? 0 : proxy.size.width * 0.44)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(Theme.backgroundGradient)
        }
        .toolbar(model.isPlayerExpanded ? .hidden : .automatic)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                model.isPlayerExpanded = false
            }
        }
    }
    #endif

    private var standardLayout: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    playerSurface
                    expandButton
                }
                .frame(
                    width: proxy.size.width,
                    height: model.isPlayerExpanded ? proxy.size.height : playerHeight(for: proxy.size)
                )
                .background(.black)
                .clipped()

                if !model.isPlayerExpanded {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                    GuideView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.backgroundGradient)
        }
        .navigationTitle(model.isPlayerExpanded ? "" : "Live TV")
    }

    @ViewBuilder
    private var expandButton: some View {
        if model.selection != nil {
            Button {
                togglePlayerSize()
            } label: {
                Label(
                    model.isPlayerExpanded ? "Show Guide" : "Full Screen",
                    systemImage: model.isPlayerExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .labelStyle(.iconOnly)
                .font(.headline)
                .padding(11)
                .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(16)
            .accessibilityLabel(model.isPlayerExpanded ? "Exit full screen" : "Full screen")
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        if let selection = model.selection {
            PlayerView(selection: selection)
                .id(selection.id)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)
                Text("Choose a channel")
                    .font(.title2.bold())
                Text("Your live program will play here.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Theme.surface, .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    #if os(macOS)
    private struct MacHeroInfo: View {
        let selection: PlayerSelection?

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [Theme.surface, Theme.background, .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 13) {
                    Spacer()
                    if let selection {
                        HStack(spacing: 10) {
                            LiveBadge()
                            Text(selection.channel.name.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Text(selection.program?.title ?? selection.channel.name)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .lineLimit(2)
                        if let program = selection.program {
                            Text("\(program.start) – \(program.end)")
                                .font(.headline)
                                .foregroundStyle(Theme.accent)
                            Text(program.desc.isEmpty ? "Live programming" : program.desc)
                                .font(.body)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(4)
                        }
                    } else {
                        Text("Live TV")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("Choose a program from the guide below.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                }
                .padding(34)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    #endif

    private func playerHeight(for size: CGSize) -> CGFloat {
        #if os(tvOS)
        min(size.height * 0.58, 580)
        #elseif os(macOS)
        min(size.height * 0.58, 540)
        #else
        min(size.width * 9 / 16, size.height * 0.48)
        #endif
    }

    private func togglePlayerSize() {
        #if os(macOS)
        let window = NSApp.keyWindow
        let windowIsFullScreen = window?.styleMask.contains(.fullScreen) == true
        if model.isPlayerExpanded {
            if windowIsFullScreen {
                window?.toggleFullScreen(nil)
            }
        } else if !windowIsFullScreen {
            window?.toggleFullScreen(nil)
        }
        #endif
        withAnimation(.easeInOut(duration: 0.24)) {
            model.isPlayerExpanded.toggle()
        }
    }
}
