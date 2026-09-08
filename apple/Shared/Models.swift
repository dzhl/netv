import Foundation

struct GuideResponse: Decodable {
    let rows: [ChannelRow]
    let total: Int
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

    var id: String { streamID.value }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case icon
    }
}

struct Program: Decodable, Hashable {
    let title: String
    let desc: String
    let start: String
    let end: String
    let leftPercent: Double
    let widthPercent: Double

    enum CodingKeys: String, CodingKey {
        case title, desc, start, end
        case leftPercent = "left_pct"
        case widthPercent = "width_pct"
    }

    var isCurrent: Bool {
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
