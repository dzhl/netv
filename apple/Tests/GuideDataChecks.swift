import Foundation

@main
struct GuideDataChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let now = Date().timeIntervalSince1970
        func program(left: Double, width: Double, start: Double? = nil, end: Double? = nil) throws -> Program {
            var payload: [String: Any] = [
                "title": "News", "desc": "", "start": "00:00", "end": "00:00",
                "left_pct": left, "width_pct": width
            ]
            if let start { payload["start_timestamp"] = start }
            if let end { payload["end_timestamp"] = end }
            return try decoder.decode(
                Program.self, from: JSONSerialization.data(withJSONObject: payload)
            )
        }

        let current = try program(left: 0, width: 50, start: now - 1800, end: now + 1800)
        precondition(current.isCurrent, "Absolute broadcast times must not depend on the device time zone")
        precondition(abs(current.progress - 0.5) < 0.01)
        let upcoming = try program(left: 50, width: 50, start: now + 1800, end: now + 3600)
        precondition(!upcoming.isCurrent && upcoming.progress == 0)
        let ended = try program(left: 0, width: 10, start: now - 3600, end: now - 1800)
        precondition(!ended.isCurrent)

        let clippedLeft = try program(left: -10, width: 30)
        precondition(clippedLeft.guideRange == (0...0.2))
        let clippedRight = try program(left: 90, width: 40)
        precondition(clippedRight.guideRange == (0.9...1))
        let shortListing = try program(left: 10, width: 1)
        precondition(abs(shortListing.guideRange.upperBound - shortListing.guideRange.lowerBound - 0.01) < 0.0001)
        let offscreen = try program(left: 110, width: 10)
        precondition(offscreen.guideRange == (1...1))

        let legacy = try decoder.decode(GuideResponse.self, from: Data("""
            {"rows":[{"channel":{"stream_id":1,"name":"News","icon":""},"programs":[]}],"total":1}
            """.utf8))
        precondition(legacy.categories.isEmpty && legacy.windowStartTimestamp == nil)
        precondition(legacy.rows[0].channel.categoryIDs.isEmpty)
        precondition(clippedLeft.timeRange == "00:00 \u{2013} 00:00")

        let categorized = try decoder.decode(GuideResponse.self, from: Data("""
            {
              "rows":[{"channel":{"stream_id":"1","name":"News","icon":"","category_ids":[1,"2"]},"programs":[]}],
              "categories":[{"category_id":1,"category_name":"News"},{"category_id":"2","category_name":"Sports"}],
              "total":1,"window_start_timestamp":1789344000
            }
            """.utf8))
        precondition(categorized.categories.map(\.id) == ["1", "2"])
        precondition(categorized.rows[0].channel.categoryIDs == ["1", "2"])
        precondition(categorized.windowStartTimestamp == 1789344000)
        let duplicates = try decoder.decode([GuideCategory].self, from: Data("""
            [
              {"category_id":"sport-1","category_name":"Sports"},
              {"category_id":"news-1","category_name":"News"},
              {"category_id":"sport-2","category_name":" sports "},
              {"category_id":"sport-1","category_name":"Sports"},
              {"category_id":"news-2","category_name":"NEWS"}
            ]
            """.utf8))
        let groups = GuideCategoryGroup.distinct(duplicates)
        precondition(groups.map(\.name) == ["Sports", "News"], "Preserve category order without duplicate rows")
        precondition(groups[0].categoryIDs == ["sport-1", "sport-2"])
        precondition(groups[1].categoryIDs == ["news-1", "news-2"])
        precondition(Set(groups.map(\.id)).count == groups.count)
        precondition(GuideCategoryGroup.distinct([]).isEmpty)
        print("Guide checks passed: timestamps, clipping, distinct categories and legacy responses")
    }
}
