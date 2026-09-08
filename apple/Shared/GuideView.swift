import SwiftUI

struct GuideView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            #if os(tvOS)
            TVGuideView()
            #elseif os(macOS)
            MacGuideView()
            #else
            PhoneGuideView()
            #endif
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .refreshable { await model.loadGuide() }
    }
}

#if os(macOS)
private struct MacGuideView: View {
    @EnvironmentObject private var model: AppModel

    private let channelWidth: CGFloat = 190
    private let rowHeight: CGFloat = 68

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                ErrorBanner(message: error)
                    .padding(10)
            }

            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("LIVE GUIDE")
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 14)
                .frame(width: channelWidth, alignment: .leading)

                HStack(spacing: 0) {
                    ForEach(timeMarkers, id: \.self) { marker in
                        Text(marker)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 38)
            .background(Theme.background)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.filteredChannels) { row in
                        Button {
                            model.play(row)
                        } label: {
                            HStack(spacing: 0) {
                                HStack(spacing: 10) {
                                    ChannelLogo(channel: row.channel, size: 40)
                                    Text(row.channel.name)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .frame(width: channelWidth, height: rowHeight)
                                .background(
                                    model.selection?.channel.id == row.channel.id
                                        ? Theme.accent.opacity(0.2)
                                        : Theme.surface
                                )

                                GeometryReader { timeline in
                                    ZStack(alignment: .leading) {
                                        Theme.background
                                        ForEach(Array(row.programs.enumerated()), id: \.offset) { _, program in
                                            MacEPGCell(program: program)
                                                .frame(
                                                    width: max(
                                                        timeline.size.width * program.widthPercent / 100 - 3,
                                                        70
                                                    ),
                                                    height: rowHeight - 6
                                                )
                                                .offset(
                                                    x: timeline.size.width * program.leftPercent / 100 + 2
                                                )
                                        }
                                    }
                                    .clipped()
                                }
                                .frame(height: rowHeight)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var timeMarkers: [String] {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: 0,
            second: 0,
            of: now
        ) ?? now
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return (0..<7).compactMap {
            calendar.date(byAdding: .minute, value: $0 * 30, to: start)
        }.map(formatter.string)
    }
}

private struct MacEPGCell: View {
    let program: Program

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(program.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("\(program.start) – \(program.end)")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(program.isCurrent ? Theme.accent.opacity(0.72) : Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    program.isCurrent ? Color.white.opacity(0.55) : Color.white.opacity(0.07),
                    lineWidth: 1
                )
        }
    }
}
#endif

#if os(iOS)
private struct PhoneGuideView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                ForEach(model.filteredChannels) { row in
                    Button {
                        model.play(row)
                    } label: {
                        PhoneChannelCard(row: row)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Live TV")
        .searchable(text: $model.query, prompt: "Channels and programs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isLoading {
                    ProgressView()
                } else {
                    Text("\(model.filteredChannels.count) channels")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }
}

private struct PhoneChannelCard: View {
    let row: ChannelRow

    var body: some View {
        HStack(spacing: 14) {
            ChannelLogo(channel: row.channel, size: 58)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.channel.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    LiveBadge()
                }
                if let program = row.currentProgram {
                    Text(program.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack {
                        Text("\(program.start) – \(program.end)")
                        Spacer()
                        Text("\(Int(program.progress * 100))%")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    ProgressView(value: program.progress)
                        .tint(Theme.accent)
                } else {
                    Text("Program information unavailable")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
        }
        .padding(14)
        .glassCard()
        .contentShape(Rectangle())
    }
}
#endif

#if os(tvOS)
private struct TVGuideView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [
        GridItem(.adaptive(minimum: 360, maximum: 500), spacing: 28)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LIVE NOW")
                            .font(.caption.weight(.bold))
                            .tracking(3)
                            .foregroundStyle(Theme.accent)
                        Text("Live TV")
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Text("\(model.filteredChannels.count) channels")
                        .foregroundStyle(Theme.secondaryText)
                }

                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(model.filteredChannels) { row in
                        Button {
                            model.play(row)
                        } label: {
                            TVChannelCard(row: row)
                        }
                        .buttonStyle(TVCardButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 70)
            .padding(.vertical, 36)
        }
    }
}

private struct TVChannelCard: View {
    let row: ChannelRow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                ChannelLogo(channel: row.channel, size: 76)
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.channel.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    LiveBadge()
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }
            if let program = row.currentProgram {
                VStack(alignment: .leading, spacing: 8) {
                    Text(program.title)
                        .font(.title3.weight(.medium))
                        .lineLimit(1)
                    Text(program.desc)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                    ProgressView(value: program.progress)
                        .tint(Theme.accent)
                    Text("\(program.start) – \(program.end)")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            } else {
                Text("Program information unavailable")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct TVCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
#endif

struct ChannelLogo: View {
    let channel: Channel
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.white.opacity(0.09))
            if let url = URL(string: channel.icon), !channel.icon.isEmpty {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        fallback
                    }
                }
                .padding(size * 0.1)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
    }

    private var fallback: some View {
        Text(channel.name.prefix(2).uppercased())
            .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.live)
                .frame(width: 7, height: 7)
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
        }
        .foregroundStyle(.white.opacity(0.8))
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
