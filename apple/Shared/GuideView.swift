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

private struct GuideTimeNavigation: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Earlier", systemImage: "chevron.left") {
                    Task { await model.loadGuide(offset: model.requestedGuideOffset - 3) }
                }
                .disabled(model.requestedGuideOffset <= -168)
                Button("Now") {
                    Task { await model.loadGuide(offset: 0) }
                }
                Button("Later", systemImage: "chevron.right") {
                    Task { await model.loadGuide(offset: model.requestedGuideOffset + 3) }
                }
                .disabled(model.requestedGuideOffset >= 168)
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            Text(windowLabel)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel("Guide window: \(windowLabel)")
        }
    }

    private var windowLabel: String {
        let start = model.guideWindowStart
        let end = start.addingTimeInterval(3 * 3600)
        return "\(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), "
            + "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
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
                    let counts = categoryCounts
                    let playlists = model.guideCategoryGroups.filter(\.isPlaylist)
                    if !playlists.isEmpty {
                        sectionHeader("PLAYLISTS")
                        ForEach(playlists) { playlist in
                            categoryButton(
                                id: playlist.id, name: playlist.name,
                                count: counts[playlist.id, default: 0], icon: "star"
                            )
                        }
                    }
                    sectionHeader("CATEGORIES")
                    ForEach(model.guideCategoryGroups.filter { !$0.isPlaylist }) { category in
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .tracking(1.5)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 5)
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
    @State private var catchupChannel: Channel?

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
        .sheet(item: $catchupChannel) { channel in
            CatchupSheet(channel: channel)
        }

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
                Text(categoryName)
                    .font(.title3.bold())
                    .lineLimit(1)
                Text("\(rows.count) channels")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(height: GuideMetrics.scaled(54))

            GuideTimeNavigation()
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

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
                                GuideChannelRow(
                                    row: row,
                                    channelWidth: channelWidth,
                                    rowHeight: rowHeight,
                                    nowPosition: nowPosition(at: date),
                                    isPlaying: model.selection?.channel.id == row.id,
                                    focusedChannel: $focusedChannelID
                                )
                                .catchupMenu(row: row, browse: { catchupChannel = row.channel })
                                .id(row.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .disabled(model.isLoading)
                    .id([selectedCategoryID ?? "", model.query])
                    #if os(tvOS)
                    .task(id: model.isPlayerExpanded) {
                        guard !model.isPlayerExpanded,
                              let id = model.selection?.channel.id,
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
    @EnvironmentObject private var model: AppModel
    let row: ChannelRow
    let channelWidth: CGFloat
    let rowHeight: CGFloat
    let nowPosition: Double
    let isPlaying: Bool
    let focusedChannel: FocusState<String?>.Binding

    var body: some View {
        HStack(spacing: 0) {
            Button {
                #if os(tvOS)
                if isPlaying && model.selection?.isCatchup == false {
                    model.isPlayerExpanded = true
                } else {
                    model.play(row)
                }
                #else
                model.play(row)
                #endif
            } label: {
                streamLabel
            }
            .buttonStyle(GuideButtonStyle(
                isSelected: isPlaying, isFocused: focusedChannel.wrappedValue == row.id
            ))
            .focused(focusedChannel, equals: row.id)
            .accessibilityLabel("Watch \(row.channel.name) live")

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
                        GuideProgramButton(row: row, program: program)
                            .frame(
                                width: max(timeline.size.width * (range.upperBound - range.lowerBound) - 4, 0),
                                height: rowHeight - 12
                            )
                            .offset(x: timeline.size.width * range.lowerBound + 2)
                    }
                    if (0..<1).contains(nowPosition) {
                        GuideTheme.program.opacity(0.8)
                            .frame(width: 1)
                            .offset(x: timeline.size.width * nowPosition)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
            }
            .frame(height: rowHeight)
        }
    }

    private var streamLabel: some View {
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
    }
}

private struct GuideProgramButton: View {
    @EnvironmentObject private var model: AppModel
    let row: ChannelRow
    let program: Program
    @FocusState private var focused: Bool

    var body: some View {
        let available = model.canPlayProgram(program, in: row)
        let playing = model.isPlayingProgram(program, in: row)
        Button {
            #if os(tvOS)
            if playing {
                model.isPlayerExpanded = true
            } else {
                model.playProgram(program, in: row)
            }
            #else
            model.playProgram(program, in: row)
            #endif
        } label: {
            GuideProgramCell(program: program)
        }
        .buttonStyle(GuideButtonStyle(isSelected: playing, isFocused: focused))
        .focused($focused)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
        .accessibilityLabel("\(program.title), \(program.timeRange)")
        .accessibilityValue(available ? (playing ? "Playing" : "Available") : "Unavailable")
        #if os(macOS)
        .help(available ? program.title : "This program is not available to play")
        #endif
    }
}

private struct GuideProgramCell: View {
    let program: Program

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                if program.catchup { Image(systemName: "clock.arrow.circlepath") }
                Text(program.title).lineLimit(1)
            }
            .font(.system(size: GuideMetrics.fontSize(12), weight: .semibold))
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
    @State private var catchupChannel: Channel?

    var body: some View {
        VStack(spacing: 0) {
            GuideTimeNavigation()
                .padding(16)
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let error = model.errorMessage {
                        ErrorBanner(message: error)
                    }
                    ForEach(model.filteredChannels) { row in
                        VStack(spacing: 4) {
                            Button {
                                model.play(row)
                            } label: {
                                PhoneChannelCard(row: row)
                            }
                            .buttonStyle(.plain)
                            .catchupMenu(row: row, browse: { catchupChannel = row.channel })
                            ForEach(Array(row.programs.enumerated()), id: \.offset) { _, program in
                                programButton(program, row: row)
                            }
                        }
                        .disabled(model.isLoading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Live TV")
        .searchable(text: $model.query, prompt: "Channels and programs")
        .sheet(item: $catchupChannel) { channel in
            CatchupSheet(channel: channel)
        }
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

    private func programButton(_ program: Program, row: ChannelRow) -> some View {
        let available = model.canPlayProgram(program, in: row)
        return Button {
            model.playProgram(program, in: row)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.title).font(.subheadline.weight(.semibold))
                    Text(program.timeRange)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: available
                    ? (program.catchup ? "clock.arrow.circlepath" : "play.circle")
                    : "clock")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
        .accessibilityLabel("\(program.title), \(program.timeRange)")
        .accessibilityValue(available ? "Available" : "Unavailable")
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
                        Text(program.timeRange)
                        Spacer()
                        Text("\(Int(program.progress * 100))%")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    ProgressView(value: program.progress)
                        .tint(Theme.accent)
                } else {
                    Text("Watch live")
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

struct CatchupBadge: View {
    var body: some View {
        Label("CATCH-UP", systemImage: "clock.arrow.circlepath")
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.8))
    }
}

private struct CatchupMenu: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let row: ChannelRow
    let browse: () -> Void

    func body(content: Content) -> some View {
        if row.channel.catchupDays > 0 {
            content.contextMenu {
                if let program = model.startOverProgram(for: row) {
                    Button {
                        model.playCatchup(row.channel, program: program)
                    } label: {
                        Label("Start Over", systemImage: "backward.end.fill")
                    }
                }
                Button(action: browse) {
                    Label("Catch Up…", systemImage: "clock.arrow.circlepath")
                }
                if model.selection?.channel.id == row.id, model.selection?.isCatchup == true {
                    Button {
                        model.play(row)
                    } label: {
                        Label("Watch Live", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    /// Start Over and Catch Up actions for channels whose upstream keeps an archive.
    func catchupMenu(row: ChannelRow, browse: @escaping () -> Void) -> some View {
        modifier(CatchupMenu(row: row, browse: browse))
    }
}

/// Past programs still in a channel's archive, newest first.
struct CatchupSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: Channel

    @State private var programs: [Program]?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    ContentUnavailableView(
                        "Catch Up Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if let programs, programs.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Catch Up On",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("No earlier programs are listed for \(channel.name).")
                    )
                } else if let programs {
                    List(Array(programs.enumerated()), id: \.offset) { _, program in
                        Button {
                            model.playCatchup(channel, program: program)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(program.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    if program.isCurrent {
                                        Text("ON NOW")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Theme.live)
                                    }
                                }
                                Text(program.archiveLabel)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                if !program.desc.isEmpty {
                                    Text(program.desc)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ProgressView("Loading earlier programs…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Catch Up: \(channel.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .task {
            do {
                programs = try await model.catchupPrograms(for: channel)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
