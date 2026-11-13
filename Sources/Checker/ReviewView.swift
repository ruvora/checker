import AppKit
import SwiftUI
import CheckerCore

struct ReviewView: View {
    @ObservedObject var model: AppModel
    @Binding var period: ReviewPeriod
    @Binding var date: Date
    private let calendar = ReviewPeriod.calendar()
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var range: Range<Date> { period.range(containing: date, calendar: calendar) }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 690
            let review = CompletedReview(items: model.document.items, in: range, calendar: calendar)
            VStack(spacing: 0) {
                Divider().overlay(Palette.line)
                FlowLayout(spacing: 6) {
                    periodPicker
                    dateNavigation
                    toolbarButton(model.text("오늘")) { date = today }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider().overlay(Palette.line)
                if wide {
                    HStack(spacing: 0) {
                        ScrollView { calendarPanel(review.countsByDay).padding(16) }
                            .frame(width: 258)
                        Divider().overlay(Palette.line)
                        ScrollView { results(review, wide: true).padding(16) }
                            .id(range)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            calendarPanel(review.countsByDay, compact: true)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                            Divider().overlay(Palette.line)
                            results(review, wide: false).padding(16)
                        }
                    }
                    .id(range)
                }
            }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(ReviewPeriod.allCases) { choice in
                Button { period = choice } label: {
                    Text(periodName(choice, short: true))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(choice == period ? Palette.accent : Palette.muted)
                        .padding(.horizontal, 7).frame(height: 24)
                        .background(choice == period ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(periodName(choice))
                .accessibilityAddTraits(choice == period ? .isSelected : [])
            }
        }
        .padding(2).background(Palette.soft, in: RoundedRectangle(cornerRadius: 7))
    }

    private var dateNavigation: some View {
        HStack(spacing: 4) {
            stepButton(-1)
            Text(periodLabel)
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            stepButton(1)
        }
    }

    private func stepButton(_ direction: Int) -> some View {
        let label = model.text(direction < 0 ? "이전 기간" : "다음 기간")
        return Button { date = period.move(date, by: direction, calendar: calendar) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 23, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(Palette.muted).help(label).accessibilityLabel(label)
    }

    private func toolbarButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).frame(height: 26)
                .foregroundColor(Palette.accent)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func calendarPanel(_ counts: [Date: Int], compact: Bool = false) -> some View {
        let days = ReviewPeriod.monthGrid(containing: date, calendar: calendar)
        var calendar = calendar
        calendar.locale = model.language.locale
        let weekdays = calendar.veryShortStandaloneWeekdaySymbols
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(monthLabel).font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(model.text("숫자 = 완료 건수")).font(.system(size: 9)).foregroundColor(Palette.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 2), count: 7), spacing: 2) {
                ForEach(0..<7) { index in
                    Text(weekdays[(index + calendar.firstWeekday - 1) % 7])
                        .font(.system(size: 10)).foregroundColor(Palette.muted).padding(.bottom, 3)
                        .accessibilityHidden(true)
                }
                ForEach(days, id: \.self) { day in
                    dateButton(day, count: counts[calendar.startOfDay(for: day), default: 0], height: compact ? 26 : 32)
                }
            }
        }
    }

    private func dateButton(_ day: Date, count: Int, height: CGFloat) -> some View {
        let anchor = calendar.isDate(day, inSameDayAs: date)
        let currentDay = calendar.isDate(day, inSameDayAs: today)
        let inMonth = calendar.isDate(day, equalTo: date, toGranularity: .month)
        let selected = range.contains(day)
        return Button { date = day } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 11, weight: anchor || currentDay ? .semibold : .regular))
                    .underline(currentDay)
                if count > 0 {
                    Text(model.text("{count}건", ["count": String(count)]))
                        .font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.65)
                }
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity).frame(height: height)
            .foregroundColor(anchor ? Palette.background : selected || currentDay ? Palette.accent : inMonth ? .primary : Palette.muted)
            .background(anchor ? Palette.accent : selected ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(format(day, with: dayStyle.year()) + (currentDay ? ", " + model.text("오늘") : ""))
        .accessibilityValue(completionCount(count))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func results(_ review: CompletedReview, wide: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(completionCount(review.count)).font(.system(size: 11, weight: .medium)).foregroundColor(Palette.accent)
                    .fixedSize()
            }
            if review.count > 0 { summary(review) }
            HStack(spacing: 7) {
                Text(model.text("완료한 항목")).font(.system(size: 11, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(model.text("완료일 기준")).font(.system(size: 10)).foregroundColor(Palette.muted)
            }
            if review.count == 0 {
                Text(model.text("이 기간에 완료한 항목이 없습니다."))
                    .font(.system(size: 12)).foregroundColor(Palette.muted).padding(.vertical, 14)
            }
            ForEach(review.days) { day in
                if period != .day {
                    Text(format(day.date, with: dayStyle))
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Palette.muted)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(day.items) { item in
                    taskRow(item, wide: wide)
                    if item.id != day.items.last?.id { Divider().overlay(Palette.line) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ review: CompletedReview) -> some View {
        let shown = review.categories.prefix(3)
        let remaining = review.count - shown.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 5) {
            Text(model.text("요약")).font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.accent)
                .accessibilityAddTraits(.isHeader)
            ForEach(shown) { category in
                let label = model.text("{category} {count}건", ["category": model.categoryName(category.id), "count": String(category.count)])
                (Text(label).fontWeight(.medium) + Text(" · " + category.recentTitles.joined(separator: " · ")))
                    .font(.system(size: 11)).lineLimit(2)
            }
            if remaining > 0 {
                Text(model.text("다른 카테고리 {count}건", ["count": String(remaining)]))
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(Palette.soft, in: RoundedRectangle(cornerRadius: 8))
    }

    private func taskRow(_ item: ChecklistItem, wide: Bool) -> some View {
        let source = model.text(item.sourceApp.label)
        let metadata = HStack(spacing: 4) {
            CategoryDot(color: model.categoryColor(item.categoryID))
            Text(model.categoryName(item.categoryID) + " · " + source)
                .font(.system(size: 10)).foregroundColor(Palette.muted)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .medium))
                .foregroundColor(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let url = item.sourceURL {
                    Button { model.openSource(item) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(item.title).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundColor(Palette.muted)
                        }
                    }
                    .buttonStyle(.plain).help(url)
                    .accessibilityLabel(model.text("{title}, {source} 원문 열기", ["title": item.title, "source": source]))
                } else {
                    Text(item.title).fixedSize(horizontal: false, vertical: true)
                }
                if !wide { metadata }
                TaskContextLine(item: item, language: model.language)
            }
            .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            if wide { metadata.lineLimit(1).frame(maxWidth: 145, alignment: .trailing) }
        }
        .contextMenu {
            Button(model.text("작업 출처 편집…")) { model.contextItem = item }
            if !item.note.isEmpty { Button(model.text("메모 보기")) { model.noteItem = item } }
            if let link = item.sourceURL {
                Button(model.text("원문 링크 복사")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
        }
    }

    private func periodName(_ value: ReviewPeriod, short: Bool = false) -> String {
        switch value {
        case .day: return model.text(short ? "일" : "일간")
        case .week: return model.text(short ? "주" : "주간")
        case .month: return model.text(short ? "월" : "월간")
        }
    }

    private func completionCount(_ count: Int) -> String {
        model.text(count == 1 ? "완료 1건" : "완료 {count}건", ["count": String(count)])
    }

    private func format(_ value: Date, with style: Date.FormatStyle) -> String {
        var style = style
        style.locale = model.language.locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style.format(value)
    }

    private var dayStyle: Date.FormatStyle { .dateTime.month(.abbreviated).day().weekday(.wide) }
    private var monthLabel: String { format(date, with: .dateTime.year().month(.wide)) }
    private var periodLabel: String {
        switch period {
        case .day:
            return format(date, with: .dateTime.month(.abbreviated).day())
        case .week:
            let end = calendar.date(byAdding: .day, value: -1, to: range.upperBound)!
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            let includeYear = !calendar.isDate(range.lowerBound, equalTo: end, toGranularity: .year)
            let endpointStyle = includeYear ? style.year() : style
            return format(range.lowerBound, with: endpointStyle) + "–" + format(end, with: endpointStyle)
        case .month:
            return monthLabel
        }
    }

    private var heading: String {
        switch period {
        case .day:
            if range.contains(today) { return model.text("오늘 한 일") }
            let style = calendar.isDate(date, equalTo: today, toGranularity: .year) ? dayStyle : dayStyle.year()
            return model.text("{date}에 한 일", ["date": format(date, with: style)])
        case .week:
            if range.contains(today) { return model.text("이번 주에 한 일") }
            return model.text("{date}에 한 일", ["date": periodLabel])
        case .month:
            let label = calendar.isDate(date, equalTo: today, toGranularity: .year)
                ? format(date, with: .dateTime.month(.wide)) : monthLabel
            return model.text("{month}에 한 일", ["month": label])
        }
    }
}
