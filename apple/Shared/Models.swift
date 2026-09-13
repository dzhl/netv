import Foundation

struct GuideResponse: Decodable {
    var rows: [ChannelRow]
    let categories: [GuideCategory]
    let total: Int
    let windowStartTimestamp: Double?

    enum CodingKeys: String, CodingKey {
        case rows, categories, total
        case windowStartTimestamp = "window_start_timestamp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode([ChannelRow].self, forKey: .rows)
        categories = try container.decodeIfPresent([GuideCategory].self, forKey: .categories) ?? []
        total = try container.decode(Int.self, forKey: .total)
        windowStartTimestamp = try container.decodeIfPresent(Double.self, forKey: .windowStartTimestamp)
    }
}

struct GuideCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(FlexibleID.self, forKey: .id).value
        name = try container.decode(String.self, forKey: .name)
    }
}

struct ChannelRow: Decodable, Identifiable, Hashable {
    let channel: Channel
    let programs: [Program]

    var id: String { channel.id }
    var currentProgram: Program? {
        programs.first(where: \.isCurrent) ?? programs.first
    }
}

struct Channel: Decodable, Identifiable, Hashable {
    let streamID: FlexibleID
    let name: String
    let icon: String
    let categoryIDs: [String]

    var id: String { streamID.value }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case icon
        case categoryIDs = "category_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decode(FlexibleID.self, forKey: .streamID)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? ""
        let categories = try container.decodeIfPresent(
            [FlexibleID].self,
            forKey: .categoryIDs
        ) ?? []
        categoryIDs = categories.map(\.value)
    }
}

struct Program: Decodable, Hashable {
    let title: String
    let desc: String
    let start: String
    let end: String
    let leftPercent: Double
    let widthPercent: Double
    let startTimestamp: Double?
    let endTimestamp: Double?

    enum CodingKeys: String, CodingKey {
        case title, desc, start, end
        case leftPercent = "left_pct"
        case widthPercent = "width_pct"
        case startTimestamp = "start_timestamp"
        case endTimestamp = "end_timestamp"
    }

    var timeRange: String {
        guard let startTimestamp, let endTimestamp else { return "\(start) – \(end)" }
        let startDate = Date(timeIntervalSince1970: startTimestamp)
        let endDate = Date(timeIntervalSince1970: endTimestamp)
        return "\(startDate.formatted(date: .omitted, time: .shortened)) – \(endDate.formatted(date: .omitted, time: .shortened))"
    }

    var guideRange: ClosedRange<Double> {
        let lower = min(max(leftPercent / 100, 0), 1)
        let upper = min(max((leftPercent + widthPercent) / 100, lower), 1)
        return lower...upper
    }

    var isCurrent: Bool {
        if let startTimestamp, let endTimestamp {
            let now = Date().timeIntervalSince1970
            return now >= startTimestamp && now < endTimestamp
        }
        guard let startDate = Self.timeFormatter.date(from: start),
              let endDate = Self.timeFormatter.date(from: end) else { return false }
        let now = Date()
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute], from: startDate)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endDate)
        guard let todayStart = calendar.date(
            bySettingHour: startComponents.hour ?? 0,
            minute: startComponents.minute ?? 0,
            second: 0,
            of: now
        ), var todayEnd = calendar.date(
            bySettingHour: endComponents.hour ?? 0,
            minute: endComponents.minute ?? 0,
            second: 0,
            of: now
        ) else { return false }
        if todayEnd <= todayStart {
            todayEnd = calendar.date(byAdding: .day, value: 1, to: todayEnd) ?? todayEnd
        }
        return now >= todayStart && now < todayEnd
    }

    var progress: Double {
        if let startTimestamp, let endTimestamp {
            guard isCurrent, endTimestamp > startTimestamp else { return 0 }
            return min(max((Date().timeIntervalSince1970 - startTimestamp) / (endTimestamp - startTimestamp), 0), 1)
        }
        guard isCurrent,
              let startDate = Self.timeFormatter.date(from: start),
              let endDate = Self.timeFormatter.date(from: end) else { return 0 }
        let calendar = Calendar.current
        let now = Date()
        let startComponents = calendar.dateComponents([.hour, .minute], from: startDate)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endDate)
        guard let todayStart = calendar.date(
            bySettingHour: startComponents.hour ?? 0,
            minute: startComponents.minute ?? 0,
            second: 0,
            of: now
        ), var todayEnd = calendar.date(
            bySettingHour: endComponents.hour ?? 0,
            minute: endComponents.minute ?? 0,
            second: 0,
            of: now
        ) else { return 0 }
        if todayEnd <= todayStart {
            todayEnd = calendar.date(byAdding: .day, value: 1, to: todayEnd) ?? todayEnd
        }
        return min(max(now.timeIntervalSince(todayStart) / todayEnd.timeIntervalSince(todayStart), 0), 1)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct UserPreferences: Decodable {
    let guideFilter: [String]?

    enum CodingKeys: String, CodingKey {
        case guideFilter = "guide_filter"
    }
}

struct FlexibleID: Decodable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int.self))
        }
    }
}

struct PlayerSelection: Identifiable, Hashable {
    let channel: Channel
    let program: Program?

    var id: String { channel.id }
}
