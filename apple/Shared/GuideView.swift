import SwiftUI

struct GuideView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            #if os(tvOS) || os(macOS)
            ChannelGuideView()
            #else
            PhoneGuideView()
            #endif
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .refreshable { await model.loadGuide() }
    }
}

#if os(macOS) || os(tvOS)
struct GuideSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedCategoryID: String?
    @FocusState private var focusedCategory: CategoryFocus?

    private enum CategoryFocus: Hashable {
        case category(String?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LIVE TV")
                    .font(.caption2.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Theme.secondaryText)
                Text("Categories")
                    .font(.system(size: GuideMetrics.fontSize(26), weight: .bold))
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
                    ForEach(model.guideCategoryGroups) { category in
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
        .background(GuideTheme.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Channel categories")
        .overlay(alignment: .trailing) {
            GuideTheme.divider.frame(width: 1)
        }
        .focusSection()
        .onChange(of: model.guideCategoryGroups) { _, categories in
            if let selectedCategoryID,
               !categories.contains(where: { $0.id == selectedCategoryID }) {
                self.selectedCategoryID = nil
            }
        }
    }

    private var categoryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        var groupByCategoryID: [String: String] = [:]
        for group in model.guideCategoryGroups {
            for id in group.categoryIDs {
                groupByCategoryID[id] = group.id
            }
        }
        for row in model.filteredChannels {
            for id in Set(row.channel.categoryIDs.compactMap { groupByCategoryID[$0] }) {
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
                    .font(.system(size: GuideMetrics.fontSize(13)))
                    .frame(width: GuideMetrics.scaled(18))
                    .foregroundStyle(Theme.secondaryText)
                Text(name)
                    .font(.system(size: GuideMetrics.fontSize(13), weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: GuideMetrics.scaled(44))
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(GuideButtonStyle(
            isSelected: selectedCategoryID == id, isFocused: focusedCategory == .category(id)
        ))
        .focused($focusedCategory, equals: .category(id))
        #if os(macOS)
        .help(name)
        #endif
        .accessibilityLabel("\(name), \(count) channels")
        .accessibilityValue(selectedCategoryID == id ? "Selected" : "")
    }
}

struct ChannelGuideView: View {
    @EnvironmentObject private var model: AppModel
    var selectedCategoryID: String? = nil
    @FocusState private var focusedChannelID: String?

    private var rowHeight: CGFloat { GuideMetrics.scaled(74) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GeometryReader { proxy in
                guideContent(
                    date: context.date,
                    channelWidth: min(GuideMetrics.scaled(220), proxy.size.width * 0.27)
                )
            }
        }
        .background(GuideTheme.background)
        .refreshable { await model.loadGuide() }
        .focusSection()

    }

    private var visibleChannels: [ChannelRow] {
        model.filteredChannels(in: selectedCategoryID)
    }

    private var categoryName: String {
        model.guideCategoryGroups.first(where: { $0.id == selectedCategoryID })?.name ?? "All Channels"
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
            .frame(height: GuideMetrics.scaled(54))

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
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(rows) { row in
                                Button {
                                    #if os(tvOS)
                                    if model.selection?.id == row.id {
                                        model.isPlayerExpanded = true
                                    } else {
                                        model.play(row)
                                    }
                                    #else
                                    model.play(row)
                                    #endif
                                } label: {
                                    GuideChannelRow(
                                        row: row,
                                        channelWidth: channelWidth,
                                        rowHeight: rowHeight,
                                        nowPosition: nowPosition(at: date),
                                        isPlaying: model.selection?.id == row.id
                                    )
                                }
                                .buttonStyle(GuideButtonStyle(
                                    isSelected: model.selection?.id == row.id,
                                    isFocused: focusedChannelID == row.id
                                ))
                                .id(row.id)
                                .focused($focusedChannelID, equals: row.id)
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
                    #if os(tvOS)
                    .task(id: model.isPlayerExpanded) {
                        guard !model.isPlayerExpanded,
                              let id = model.selection?.id,
                              rows.contains(where: { $0.id == id }) else { return }
                        scrollProxy.scrollTo(id, anchor: .center)
                        // Let the guide become enabled and its lazy row mount before focusing it.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        focusedChannelID = id
                    }
                    #endif
                }
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
                        .offset(x: timeline.size.width * Double(index) / 6, y: GuideMetrics.scaled(9))
                    }
                    let position = nowPosition(at: date)
                    if (0..<1).contains(position) {
                        Circle()
                            .fill(GuideTheme.program)
                            .frame(width: 6, height: 6)
                            .offset(x: timeline.size.width * position - 3, y: GuideMetrics.scaled(29))
                    }
                }
            }
        }
        .frame(height: GuideMetrics.scaled(34))
    }
}

private struct GuideChannelRow: View {
    let row: ChannelRow
    let channelWidth: CGFloat
    let rowHeight: CGFloat
    let nowPosition: Double
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                ChannelLogo(channel: row.channel, size: GuideMetrics.scaled(44))
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.channel.name)
                        .font(.system(size: GuideMetrics.fontSize(12), weight: .semibold))
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
                        GuideProgramCell(program: program)
                            .frame(
                                width: max(timeline.size.width * (range.upperBound - range.lowerBound) - 4, 0),
                                height: rowHeight - 12
                            )
                            .clipped()
                            .offset(x: timeline.size.width * range.lowerBound + 2)
                    }
                    if (0..<1).contains(nowPosition) {
                        GuideTheme.program.opacity(0.8)
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

private struct GuideProgramCell: View {
    let program: Program

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(program.title)
                .font(.system(size: GuideMetrics.fontSize(12), weight: .semibold))
                .lineLimit(1)
            Text(program.timeRange)
                .font(.system(size: GuideMetrics.fontSize(10)))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(program.isCurrent ? GuideTheme.program.opacity(0.32) : .white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    program.isCurrent ? GuideTheme.program.opacity(0.8) : .white.opacity(0.1),
                    lineWidth: 1
                )
        }
    }
}

struct GuideButtonStyle: ButtonStyle {
    var isSelected = false
    var isFocused = false

    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration, isSelected: isSelected, isFocused: isFocused)
    }

    private struct Appearance: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let isFocused: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .background(
                    isSelected ? GuideTheme.selection : GuideTheme.surface,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused ? Color.white.opacity(0.8)
                                : Color.white.opacity(isHovered ? 0.3 : 0),
                            lineWidth: isFocused ? GuideMetrics.scaled(2) : 1
                        )
                        .allowsHitTesting(false)
                }
                .brightness(configuration.isPressed ? 0.08 : (isHovered ? 0.035 : 0))
                .animation(.easeOut(duration: 0.12), value: isFocused)
                #if os(macOS)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                #endif
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
