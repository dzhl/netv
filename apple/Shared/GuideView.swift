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
struct MacGuideSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedCategoryID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LIVE TV")
                    .font(.caption2.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Theme.secondaryText)
                Text("Categories")
                    .font(.system(size: 26, weight: .bold))
            }
            .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    categoryButton(
                        id: nil, name: "All Channels",
                        count: model.filteredChannels.count, icon: "rectangle.stack"
                    )
                    Text("CATEGORIES")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 20)
                        .padding(.bottom, 5)
                    let counts = categoryCounts
                    ForEach(model.guideCategories) { category in
                        categoryButton(
                            id: category.id, name: category.name,
                            count: counts[category.id, default: 0], icon: "tv"
                        )
                    }
                    if model.guideCategories.isEmpty && !model.channels.isEmpty {
                        Text("Update your neTV server to browse categories.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)

            Label("Browse without interrupting playback", systemImage: "play.circle")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 20)
        }
        .padding(.vertical, 24)
        .frame(maxHeight: .infinity)
        .background(MacGuideTheme.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Channel categories")
        .overlay(alignment: .trailing) {
            MacGuideTheme.divider.frame(width: 1)
        }
        .onChange(of: model.guideCategories) { _, categories in
            if let selectedCategoryID,
               !categories.contains(where: { $0.id == selectedCategoryID }) {
                self.selectedCategoryID = nil
            }
        }
    }

    private var categoryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for row in model.filteredChannels {
            for id in Set(row.channel.categoryIDs) {
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    private func categoryButton(id: String?, name: String, count: Int, icon: String) -> some View {
        Button {
            selectedCategoryID = id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(Theme.secondaryText)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(MacGuideButtonStyle(isSelected: selectedCategoryID == id))
        .help(name)
        .accessibilityLabel("\(name), \(count) channels")
        .accessibilityValue(selectedCategoryID == id ? "Selected" : "")
    }
}

struct MacGuideView: View {
    @EnvironmentObject private var model: AppModel
    var selectedCategoryID: String? = nil

    private let rowHeight: CGFloat = 74

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GeometryReader { proxy in
                guideContent(date: context.date, channelWidth: min(220, proxy.size.width * 0.27))
            }
        }
        .background(MacGuideTheme.background)
        .refreshable { await model.loadGuide() }
    }

    private var visibleChannels: [ChannelRow] {
        model.filteredChannels(in: selectedCategoryID)
    }

    private var categoryName: String {
        model.guideCategories.first(where: { $0.id == selectedCategoryID })?.name ?? "All Channels"
    }

    private func guideContent(date: Date, channelWidth: CGFloat) -> some View {
        let rows = visibleChannels
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Today")
                    .font(.title3.bold())
                Text(categoryName)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Text("\(rows.count) channels")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                Text(date, style: .time)
                    .font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 20)
            .frame(height: 54)

            if let error = model.errorMessage {
                ErrorBanner(message: error)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            if model.isLoading && model.channels.isEmpty {
                ProgressView("Loading channels...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "tv")
                } description: {
                    Text(model.query.isEmpty
                         ? "Choose another category or select guide categories in the neTV web settings."
                         : "No channels or programs match your search in \(categoryName).")
                } actions: {
                    if !model.query.isEmpty {
                        Button("Clear Search") { model.query = "" }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timelineHeader(date: date, channelWidth: channelWidth)
                    .padding(.horizontal, 16)
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(rows) { row in
                            Button {
                                model.play(row)
                            } label: {
                                MacChannelRow(
                                    row: row,
                                    channelWidth: channelWidth,
                                    rowHeight: rowHeight,
                                    nowPosition: nowPosition(at: date),
                                    isPlaying: model.selection?.id == row.id
                                )
                            }
                            .buttonStyle(MacGuideButtonStyle(isSelected: model.selection?.id == row.id))
                            .accessibilityLabel("Watch \(row.channel.name)")
                            .accessibilityValue(
                                model.selection?.id == row.id ? "Now playing" : "Not playing"
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .id([selectedCategoryID ?? "", model.query])
            }
        }
    }

    private func nowPosition(at date: Date) -> Double {
        date.timeIntervalSince(model.guideWindowStart) / (3 * 60 * 60)
    }

    private func timelineHeader(date: Date, channelWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("CHANNEL")
                .font(.caption2.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.secondaryText)
                .padding(.leading, 12)
                .frame(width: channelWidth, alignment: .leading)
            GeometryReader { timeline in
                ZStack(alignment: .topLeading) {
                    ForEach(0..<6) { index in
                        Text(
                            model.guideWindowStart.addingTimeInterval(Double(index) * 30 * 60),
                            format: .dateTime.hour().minute()
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .offset(x: timeline.size.width * Double(index) / 6, y: 9)
                    }
                    let position = nowPosition(at: date)
                    if (0..<1).contains(position) {
                        Circle()
                            .fill(MacGuideTheme.program)
                            .frame(width: 6, height: 6)
                            .offset(x: timeline.size.width * position - 3, y: 29)
                    }
                }
            }
        }
        .frame(height: 34)
    }
}

private struct MacChannelRow: View {
    let row: ChannelRow
    let channelWidth: CGFloat
    let rowHeight: CGFloat
    let nowPosition: Double
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                ChannelLogo(channel: row.channel, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.channel.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    if isPlaying {
                        Label("Playing", systemImage: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: channelWidth, height: rowHeight)

            GeometryReader { timeline in
                ZStack(alignment: .leading) {
                    Color.clear
                    if row.programs.isEmpty {
                        Text("Program information unavailable")
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.leading, 16)
                    }
                    ForEach(Array(row.programs.enumerated()), id: \.offset) { _, program in
                        let range = program.guideRange
                        MacEPGCell(program: program)
                            .frame(
                                width: max(timeline.size.width * (range.upperBound - range.lowerBound) - 4, 0),
                                height: rowHeight - 12
                            )
                            .clipped()
                            .offset(x: timeline.size.width * range.lowerBound + 2)
                    }
                    if (0..<1).contains(nowPosition) {
                        MacGuideTheme.program.opacity(0.8)
                            .frame(width: 1)
                            .offset(x: timeline.size.width * nowPosition)
                    }
                }
                .clipped()
            }
            .frame(height: rowHeight)
        }
        .contentShape(Rectangle())
    }
}

private struct MacEPGCell: View {
    let program: Program

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(program.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(program.timeRange)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(program.isCurrent ? MacGuideTheme.program.opacity(0.32) : .white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    program.isCurrent ? MacGuideTheme.program.opacity(0.8) : .white.opacity(0.1),
                    lineWidth: 1
                )
        }
    }
}

struct MacGuideButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration, isSelected: isSelected)
    }

    private struct Appearance: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .background(
                    isSelected ? MacGuideTheme.selection : MacGuideTheme.surface,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused ? Color.white.opacity(0.8)
                                : Color.white.opacity(isHovered ? 0.3 : 0),
                            lineWidth: isFocused ? 2 : 1
                        )
                        .allowsHitTesting(false)
                }
                .brightness(configuration.isPressed ? 0.08 : (isHovered ? 0.035 : 0))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
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
    @State private var selectedCategoryID: String?
    @FocusState private var focusedItem: FocusedItem?

    private let categoryWidth: CGFloat = 270
    private let channelWidth: CGFloat = 330
    private let rowHeight: CGFloat = 94

    private enum FocusedItem: Hashable {
        case category(String)
        case channel(String)
    }

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar

            VStack(spacing: 0) {
                guideHeader

                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleChannels) { row in
                            Button {
                                model.play(row)
                            } label: {
                                TVChannelRow(
                                    row: row,
                                    channelWidth: channelWidth,
                                    rowHeight: rowHeight,
                                    isPlaying: model.selection?.channel.id == row.channel.id
                                )
                            }
                            .buttonStyle(
                                TVGuideRowButtonStyle(
                                    isFocused: focusedItem == .channel(row.channel.id)
                                )
                            )
                            .focused($focusedItem, equals: .channel(row.channel.id))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
            }
        }
        .onChange(of: model.guideCategories) { _, categories in
            if let selectedCategoryID,
               !categories.contains(where: { $0.id == selectedCategoryID }) {
                self.selectedCategoryID = nil
            }
        }
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIVE TV")
                    .font(.caption.weight(.bold))
                    .tracking(2.6)
                    .foregroundStyle(Theme.accent)
                Text("Categories")
                    .font(.title2.bold())
            }
            .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(spacing: 9) {
                    categoryButton(id: nil, name: "All Channels", icon: "rectangle.stack.fill")
                    ForEach(model.guideCategories) { category in
                        categoryButton(id: category.id, name: category.name, icon: "tv")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Text("\(visibleChannels.count) channels")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 20)
        }
        .padding(.vertical, 22)
        .frame(width: categoryWidth)
        .background(Theme.background.opacity(0.96))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(width: 1)
        }
    }

    private var guideHeader: some View {
        HStack(spacing: 0) {
            Text(selectedCategoryName)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(width: channelWidth, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(timeMarkers, id: \.self) { marker in
                    Text(marker)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: 56)
        .background(Theme.background.opacity(0.9))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
        }
    }

    private var visibleChannels: [ChannelRow] {
        model.filteredChannels(in: selectedCategoryID)
    }

    private var selectedCategoryName: String {
        guard let selectedCategoryID else { return "All Channels" }
        return model.guideCategories.first(where: { $0.id == selectedCategoryID })?.name
            ?? "Channels"
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
        return (0..<4).compactMap {
            calendar.date(byAdding: .hour, value: $0, to: start)
        }.map(formatter.string)
    }

    private func categoryButton(id: String?, name: String, icon: String) -> some View {
        let focusID = id ?? "all"
        return Button {
            selectedCategoryID = id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                Text(name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selectedCategoryID == id {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 15)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            TVCategoryButtonStyle(
                isSelected: selectedCategoryID == id,
                isFocused: focusedItem == .category(focusID)
            )
        )
        .focused($focusedItem, equals: .category(focusID))
    }
}

private struct TVChannelRow: View {
    let row: ChannelRow
    let channelWidth: CGFloat
    let rowHeight: CGFloat
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                ChannelLogo(channel: row.channel, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.channel.name)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if isPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(Theme.accent)
                        }
                        Text(row.currentProgram?.title ?? "No guide information")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: channelWidth, height: rowHeight)

            GeometryReader { timeline in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.025)
                    ForEach(Array(row.programs.enumerated()), id: \.offset) { _, program in
                        TVProgramCell(program: program)
                            .frame(
                                width: max(timeline.size.width * program.widthPercent / 100 - 5, 100),
                                height: rowHeight - 12
                            )
                            .offset(x: timeline.size.width * program.leftPercent / 100 + 3)
                    }
                }
                .clipped()
            }
            .frame(height: rowHeight)
        }
        .background(isPlaying ? Theme.accent.opacity(0.12) : Theme.surface.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isPlaying ? Theme.accent.opacity(0.65) : Color.white.opacity(0.06))
        }
    }
}

private struct TVProgramCell: View {
    let program: Program

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(program.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("\(program.start) – \(program.end)")
                .font(.caption2)
                .foregroundStyle(program.isCurrent ? .white.opacity(0.78) : Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(program.isCurrent ? Theme.accent.opacity(0.8) : Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct TVGuideRowButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.018 : (configuration.isPressed ? 0.99 : 1))
            .shadow(color: isFocused ? Theme.accent.opacity(0.5) : .clear, radius: 12)
            .animation(.easeOut(duration: 0.14), value: isFocused)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct TVCategoryButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                isSelected ? Theme.accent.opacity(0.72) : Theme.surface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? Color.white.opacity(0.9) : .clear, lineWidth: 3)
            }
            .scaleEffect(isFocused ? 1.045 : (configuration.isPressed ? 0.98 : 1))
            .animation(.easeOut(duration: 0.14), value: isFocused)
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
