import Foundation

public enum ReviewPeriod: String, CaseIterable, Identifiable {
    case day, week, month

    public var id: Self { self }

    public static func calendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    public func range(containing date: Date, calendar: Calendar) -> Range<Date> {
        let interval = calendar.dateInterval(of: component, for: date)!
        return interval.start..<interval.end
    }

    public func move(_ date: Date, by amount: Int, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: component, value: amount, to: date)!)
    }

    public static func monthGrid(containing date: Date, calendar: Calendar) -> [Date] {
        let monthStart = Self.month.range(containing: date, calendar: calendar).lowerBound
        let weekStart = Self.week.range(containing: monthStart, calendar: calendar).lowerBound
        return (0..<42).map { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: weekStart)!)
        }
    }
}

/// A projection of the archive. Restoring or deleting an item removes it from the review.
public struct CompletedReview {
    public struct Day: Identifiable {
        public let date: Date
        public let items: [ChecklistItem]
        public var id: Date { date }
    }

    public struct Category: Identifiable {
        public let id: String
        public let count: Int
        public let recentTitles: [String]
    }

    public let days: [Day]
    public let countsByDay: [Date: Int]
    public let count: Int
    public let categories: [Category]

    public init(items: [ChecklistItem], in range: Range<Date>, calendar: Calendar) {
        var counts: [Date: Int] = [:]
        var groups: [Date: [(date: Date, item: ChecklistItem)]] = [:]
        for item in items {
            guard let completion = item.archivedAt else { continue }
            let day = calendar.startOfDay(for: completion)
            counts[day, default: 0] += 1
            if range.contains(completion) { groups[day, default: []].append((completion, item)) }
        }
        countsByDay = counts
        let days = groups.keys.sorted(by: >).map { date in
            Day(date: date, items: groups[date, default: []].sorted {
                $0.date == $1.date ? $0.item.id < $1.item.id : $0.date > $1.date
            }.map(\.item))
        }
        self.days = days
        let selected = days.flatMap(\.items)
        count = selected.count
        let grouped = Dictionary(grouping: selected, by: \.categoryID)
        let exampleLimit = grouped.count == 1 ? 3 : 1
        categories = grouped.map { id, items in
            Category(id: id, count: items.count, recentTitles: items.prefix(exampleLimit).map(\.title))
        }.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }
}
