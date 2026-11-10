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
    try check("agent setup consumes only a fresh private request for the selected home") { directory in
        let home = directory.appendingPathComponent("user", isDirectory: true)
        let data = home.appendingPathComponent("Library/Application Support/Checker")
        let pending = AgentSetupRequest.pendingURL(in: data)
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let value: [String: Any] = ["schemaVersion": 1, "requestID": id, "createdAt": 1000,
                                  "home": home.path, "connections": "codex,chrome,claude", "language": "en"]
        try JSONSerialization.data(withJSONObject: value).write(to: pending)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        let request = try AgentSetupRequest.loadPending(in: data, now: Date(timeIntervalSince1970: 1100))
        try expect(request?.id == id && request?.language == .english, "valid pending setup was not read")
        try expect(Set(request!.connections) == Set(["codex", "chrome", "claude"]), "connection selection changed")
        let expired = try AgentSetupRequest.loadPending(in: data, now: Date(timeIntervalSince1970: 5000))
        try expect(expired == nil, "expired setup request was accepted")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pending.path)
        let publicRequest = try AgentSetupRequest.loadPending(in: data, now: Date(timeIntervalSince1970: 1100))
        try expect(publicRequest == nil, "non-private setup request was accepted")
        do {
            _ = try AgentSetupRequest.parse(["Checker", "--agent-setup", id, "--connections", "chrome", "--setup-home", home.path], dataDirectory: directory)
            throw CheckerError.invalid("cross-home request accepted")
        } catch CheckerError.invalid(let message) where message != "cross-home request accepted" {}
        try request!.writeReceipt(status: "configured", app: home.appendingPathComponent("Applications/Checker.app"), version: "0.4.0", language: .english)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: request!.receiptURL)) as! [String: Any]
        try expect(receipt["status"] as? String == "configured", "setup receipt missing")
        try expect((receipt["remainingActions"] as? [String])?.contains("chrome_extension_add_or_reload") == true, "manual Chrome step was omitted")
        try request!.clearPending()
        try expect(!FileManager.default.fileExists(atPath: pending.path), "completed pending request was not removed")
    }
    print("8 core checks passed")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
