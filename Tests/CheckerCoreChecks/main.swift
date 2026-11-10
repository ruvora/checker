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
    try check("invalid links cannot mutate persisted data") { directory in
        let repo = try ChecklistRepository(directory: directory)
        for link in ["javascript:alert(1)", "codex://plugins/install/example", "file:///etc/passwd"] {
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
    print("7 core checks passed")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
