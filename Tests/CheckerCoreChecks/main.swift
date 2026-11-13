import Foundation
import CheckerCore

// Command Line Tools does not ship XCTest; these executable checks need no Xcode installation.
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckerError.invalid(message) }
}
func check(_ name: String, _ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("checker-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
    print("PASS \(name)")
}
do {
    try check("review uses local completion dates, Monday weeks, and exclusive period ends") { directory in
        let calendar = ReviewPeriod.calendar(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let iso = ISO8601DateFormatter()
        func time(_ value: String) -> Date { iso.date(from: value)! }
        let repo = try ChecklistRepository(directory: directory)
        let older = try repo.add(CaptureRequest(title: "Older review", categoryID: "review"), now: time("2025-02-01T00:00:00Z"))
        let latest = try repo.add(CaptureRequest(title: "Latest review", categoryID: "review"))
        let monday = try repo.add(CaptureRequest(title: "Fix", categoryID: "development"))
        let nextMonday = try repo.add(CaptureRequest(title: "Next week"))
        _ = try repo.add(CaptureRequest(title: "Still active"))
        let beforeClockChange = time("2025-03-09T09:30:00Z")
        let afterClockChange = time("2025-03-10T06:59:59Z")
        try repo.archive(older.id, now: beforeClockChange)
        try repo.archive(latest.id, now: afterClockChange)
        try repo.archive(monday.id, now: time("2025-03-03T08:00:00Z"))
        try repo.archive(nextMonday.id, now: time("2025-03-10T07:00:00Z"))
        let week = ReviewPeriod.week.range(containing: beforeClockChange, calendar: calendar)
        try expect(week == time("2025-03-03T08:00:00Z")..<time("2025-03-10T07:00:00Z"), "week did not run from local Monday to Monday across DST")
        let review = CompletedReview(items: repo.document.items, in: week, calendar: calendar)
        try expect(review.days.map { $0.items.map(\.id) } == [[latest.id, older.id], [monday.id]], "week did not group and order items by completion time")
        try expect(review.categories.first?.count == 2 && review.categories.first?.recentTitles == ["Latest review"], "summary did not use the latest title from the leading category")
        try expect(review.countsByDay[week.upperBound] == 1, "calendar lost a completion outside the selected week")
        let day = ReviewPeriod.day.range(containing: beforeClockChange, calendar: calendar)
        try expect(CompletedReview(items: repo.document.items, in: day, calendar: calendar).count == 2, "one local day crossed a UTC date")
        try repo.restore(latest.id)
        try repo.delete([older.id])
        let updated = CompletedReview(items: repo.document.items, in: day, calendar: calendar)
        try expect(updated.count == 0 && updated.countsByDay[day.lowerBound] == nil, "restored or deleted items remained in review")
    }
    try check("review month navigation and grid use the local calendar") { _ in
        let calendar = ReviewPeriod.calendar(timeZone: TimeZone(identifier: "Asia/Seoul")!)
        let iso = ISO8601DateFormatter()
        func time(_ value: String) -> Date { iso.date(from: value)! }
        let january31 = time("2024-01-30T15:00:00Z")
        let leapDay = ReviewPeriod.month.move(january31, by: 1, calendar: calendar)
        try expect(leapDay == time("2024-02-28T15:00:00Z"), "month navigation skipped leap February")
        let month = ReviewPeriod.month.range(containing: leapDay, calendar: calendar)
        try expect(month == time("2024-01-31T15:00:00Z")..<time("2024-02-29T15:00:00Z"), "month boundaries were not local midnights")
        let grid = ReviewPeriod.monthGrid(containing: leapDay, calendar: calendar)
        try expect(grid.count == 42 && grid.first == time("2024-01-28T15:00:00Z") && grid.filter(month.contains).count == 29, "grid did not show the full leap month starting on Monday")
    }
    try check("archive, restore and reload preserve the original link and category") { directory in
        let repo = try ChecklistRepository(directory: directory)
        let request = CaptureRequest(title: "검토", sourceApp: .codex, sourceURL: "codex://threads/12345678-abcd-1234-abcd-123456789012", categoryID: "review")
        let item = try repo.add(request)
        try repo.archive(item.id)
        try expect(repo.document.items[0].isArchived, "archive failed")
        try repo.restore(item.id)
        let saved = try ChecklistRepository(directory: directory).document.items[0]
        try expect(saved.id == item.id && saved.sourceURL == item.sourceURL && saved.categoryID == "review" && !saved.isArchived, "restore lost item metadata")
    }
    try check("replayed captures remain idempotent even after archiving") { directory in
        let repo = try ChecklistRepository(directory: directory)
        let request = CaptureRequest(title: "한 번만 추가")
        let item = try repo.add(request)
        try repo.archive(item.id)
        _ = try repo.add(request)
        try expect(repo.document.items.count == 1 && repo.document.items[0].isArchived, "duplicate capture changed the item")
    }
    try check("only archived items are deleted, undo puts them back, and replays stay deleted") { directory in
        let repo = try ChecklistRepository(directory: directory)
        let active = try repo.add(CaptureRequest(title: "진행 중"))
        let request = CaptureRequest(title: "끝난 일", sourceURL: "https://example.com/done", categoryID: "review")
        let file = directory.appendingPathComponent("inbox/\(request.requestID).json")
        let data = try JSONEncoder().encode(request)
        try data.write(to: file, options: .atomic)
        _ = try repo.drainInbox()
        let done = repo.document.items.first { $0.title == "끝난 일" }!
        do { try repo.delete([active.id]); throw CheckerError.invalid("active item deleted") }
        catch CheckerError.invalid(let message) where message != "active item deleted" {}
        try repo.archive(done.id)
        let removed = try repo.delete([done.id])
        let reloaded = try ChecklistRepository(directory: directory)
        try expect(reloaded.document.items.map(\.id) == [active.id], "delete was not persisted")
        try repo.reinsert(removed)
        let back = try ChecklistRepository(directory: directory).document.items.first { $0.id == done.id }
        try expect(back?.sourceURL == "https://example.com/done" && back?.categoryID == "review" && back?.isArchived == true, "undo lost item metadata")
        try repo.delete([done.id])
        try data.write(to: file, options: .atomic)
        _ = try repo.drainInbox()
        try expect(repo.document.items.count == 1 && !FileManager.default.fileExists(atPath: file.path), "replayed request restored a deleted item")
    }
    try check("a Claude Code session link is kept as the original link") { directory in
        let repo = try ChecklistRepository(directory: directory)
        let link = "claude://code/continue?session=local_7baffd25-7faf-42e1-bda1-2f90d76a37e6"
        let item = try repo.add(CaptureRequest(title: "세션으로 돌아가기", sourceApp: .claude, sourceURL: link))
        try expect(item.sourceURL == link, "session link not kept")
        let both = try repo.add(CaptureRequest(title: "티켓 확인", sourceApp: .claude, sourceURL: link, relatedURL: "https://example.com/BP-1"))
        let saved = try ChecklistRepository(directory: directory).document.items.first { $0.id == both.id }
        try expect(saved?.sourceURL == link && saved?.relatedURL == "https://example.com/BP-1", "related link not kept separately")
        do { _ = try repo.add(CaptureRequest(title: "잘못된 관련 링크", relatedURL: "codex://threads/abc")); throw CheckerError.invalid("non-web related link accepted") }
        catch CheckerError.invalid(let message) where message != "non-web related link accepted" {}
    }
    try check("invalid links cannot mutate persisted data") { directory in
        let repo = try ChecklistRepository(directory: directory)
        for link in ["javascript:alert(1)", "codex://plugins/install/example", "file:///etc/passwd", "claude://code/new", "claude://code/continue?session=last"] {
            do { _ = try repo.add(CaptureRequest(title: "잘못된 주소", sourceURL: link)); throw CheckerError.invalid("unsafe link accepted") }
            catch CheckerError.invalid(let message) where message != "unsafe link accepted" {}
        }
        let saved = try ChecklistRepository(directory: directory)
        try expect(saved.document.items.isEmpty, "invalid item persisted")
    }
    try check("inbox receipts are committed and replay does not duplicate") { directory in
        let repo = try ChecklistRepository(directory: directory)
        let request = CaptureRequest(title: "스킬에서 등록", sourceApp: .claude, sourceURL: "https://claude.ai/chat/test", categoryID: "review")
        let file = directory.appendingPathComponent("inbox/\(request.requestID).json")
        let data = try JSONEncoder().encode(request)
        try data.write(to: file, options: .atomic)
        let count = try repo.drainInbox()
        try expect(count == 1 && !FileManager.default.fileExists(atPath: file.path), "inbox not imported")
        try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("receipts/\(request.requestID).json").path), "receipt missing")
        try data.write(to: file, options: .atomic)
        _ = try repo.drainInbox()
        try expect(repo.document.items.count == 1, "replayed request duplicated")
    }
    try check("a malformed inbox request does not block a valid request") { directory in
        let repo = try ChecklistRepository(directory: directory)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("inbox/0.json"))
        let request = CaptureRequest(title: "정상 요청", categoryID: "unknown")
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("inbox/\(request.requestID).json"))
        let count = try repo.drainInbox()
        try expect(count == 1 && repo.document.items[0].categoryID == "uncategorized", "valid request was blocked")
    }
    try check("custom categories and undo persist") { directory in
        let repo = try ChecklistRepository(directory: directory)
        try repo.addCategory(name: "프로젝트 A")
        let category = repo.document.categories.first { $0.name == "프로젝트 A" }!
        let original = try repo.add(CaptureRequest(title: "분류 변경", categoryID: "review"))
        try repo.setCategory(original.id, categoryID: category.id)
        try expect(repo.document.items[0].categoryID == category.id, "category update failed")
        try repo.replace(original)
        let saved = try ChecklistRepository(directory: directory)
        try expect(saved.document.items[0].categoryID == "review", "undo not persisted")
    }
    try check("deleting a category moves its items to 미분류 and undo restores both") { directory in
        let repo = try ChecklistRepository(directory: directory)
        try repo.addCategory(name: "프로젝트 B")
        let category = repo.document.categories.first { $0.name == "프로젝트 B" }!
        let position = repo.document.categories.firstIndex(of: category)!
        let active = try repo.add(CaptureRequest(title: "진행 중", categoryID: category.id))
        let archived = try repo.add(CaptureRequest(title: "끝남", categoryID: category.id))
        let other = try repo.add(CaptureRequest(title: "다른 일", categoryID: "review"))
        try repo.archive(archived.id)
        do { try repo.deleteCategory("uncategorized"); throw CheckerError.invalid("fallback deleted") }
        catch CheckerError.invalid(let message) where message != "fallback deleted" {}
        let removed = try repo.deleteCategory(category.id)
        let saved = try ChecklistRepository(directory: directory).document
        try expect(!saved.categories.contains { $0.id == category.id }, "category not deleted")
        try expect(saved.items.filter { $0.categoryID == "uncategorized" }.count == 2, "items not moved to 미분류")
        try expect(saved.items.first { $0.id == other.id }?.categoryID == "review", "unrelated item changed")
        try repo.restoreCategory(removed)
        let restored = try ChecklistRepository(directory: directory).document
        try expect(restored.categories.firstIndex(of: category) == position, "category not restored in place")
        try expect([active.id, archived.id].allSatisfy { id in restored.items.first { $0.id == id }?.categoryID == category.id }, "items not moved back")
    }
    try check("language preferences persist without rewriting task data or custom categories") { directory in
        let repo = try ChecklistRepository(directory: directory)
        _ = try repo.add(CaptureRequest(title: "기존 제목", note: "Original note", categoryID: "review"))
        try repo.addCategory(name: "리뷰 프로젝트")
        let before = try Data(contentsOf: directory.appendingPathComponent("checklist.json"))
        let settings = LanguageSettings(directory: directory)
        try settings.save(.english)
        let loaded = try settings.load()
        try expect(loaded == .english, "language was not persisted")
        try expect(repo.document.categories[1].displayName(in: loaded) == "Review", "default category not localized")
        let custom = repo.document.categories.first { $0.id.hasPrefix("custom-") }!
        try expect(custom.displayName(in: .english) == "리뷰 프로젝트", "custom category was translated")
        try settings.save(.korean)
        let after = try Data(contentsOf: directory.appendingPathComponent("checklist.json"))
        try expect(before == after, "language change rewrote saved content")
        try expect(AppLanguage.preferred(["fr-FR", "ko-KR", "en-US"]) == .korean, "supported system preference not selected")
        try expect(AppLanguage.preferred(["de-DE"]) == .english, "unsupported system language did not fall back to English")
    }
    print("All core checks passed")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
