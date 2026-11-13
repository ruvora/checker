import AppKit
import SwiftUI
import CheckerCore

enum ChecklistScope { case active, archive, review }

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published var document = ChecklistDocument()
    @Published var scope: ChecklistScope = .active
    @Published var categoryID: String?
    @Published var isCollapsed = false
    @Published var isPinned = true
    @Published var showAdd = false
    @Published var showCategoryEditor = false
    @Published var showConnections = false
    @Published var noteItem: ChecklistItem?
    @Published var contextItem: ChecklistItem?
    @Published var errorMessage: String?
    @Published var fatalError: String?
    @Published var toast: String?
    enum UndoAction { case replace(ChecklistItem), reinsert([ChecklistItem]), category(ChecklistRepository.RemovedCategory) }
    var undoAction: UndoAction?
    var onPin: ((Bool) -> Void)?
    var onCollapse: (() -> Void)?
    var onLanguageChange: (() -> Void)?
    let dataDirectory: URL
    private let languageSettings: LanguageSettings
    private var repository: ChecklistRepository?
    private var toastWork: DispatchWorkItem?

    init(directory: URL) {
        dataDirectory = directory
        languageSettings = LanguageSettings(directory: directory)
        language = (try? languageSettings.load()) ?? .preferred()
        do { let repo = try ChecklistRepository(directory: directory); repository = repo; document = repo.document }
        catch { fatalError = "목록을 읽지 못했어요. 기존 데이터는 그대로 보관되어 있습니다.\n" + error.localizedDescription }
        do {
            _ = try languageSettings.load()
            if !FileManager.default.fileExists(atPath: languageSettings.file.path) { try languageSettings.save(language) }
        } catch { errorMessage = error.localizedDescription }
    }
    func text(_ message: String, _ parameters: [String: String] = [:]) -> String {
        message.components(separatedBy: "\n").map { language.text($0, parameters) }.joined(separator: "\n")
    }
    func setLanguage(_ value: AppLanguage) {
        do {
            try languageSettings.save(value)
            applyLanguage(value)
        } catch { errorMessage = error.localizedDescription }
    }
    private func applyLanguage(_ value: AppLanguage) {
        guard language != value else { return }
        language = value; toast = nil; undoAction = nil; onLanguageChange?()
    }
    func reloadLanguage() {
        if let value = try? languageSettings.load() { applyLanguage(value) }
    }
    var showArchived: Bool { scope == .archive }
    var scopeItems: [ChecklistItem] { document.items.filter { $0.isArchived == showArchived } }
    var visibleItems: [ChecklistItem] {
        scopeItems.filter { categoryID == nil || $0.categoryID == categoryID }.sorted {
            (showArchived ? $0.archivedAt! : $0.orderDate) > (showArchived ? $1.archivedAt! : $1.orderDate)
        }
    }
    var activeCount: Int { document.items.filter { !$0.isArchived }.count }
    var archiveCount: Int { document.items.filter(\.isArchived).count }
    func categoryName(_ id: String) -> String { category(id)?.displayName(in: language) ?? text("미분류") }
    func categoryColor(_ id: String) -> CategoryColor { category(id)?.displayColor ?? .gray }
    private func category(_ id: String) -> TaskCategory? { document.categories.first { $0.id == id } }
    func categoryCount(_ id: String?) -> Int { scopeItems.filter { id == nil || $0.categoryID == id }.count }

    private func act(on item: ChecklistItem, message: String, _ action: (ChecklistRepository) throws -> Void) {
        guard let repository else { return }
        do { try action(repository); document = repository.document; undoAction = .replace(item); announce(message) }
        catch { errorMessage = error.localizedDescription }
    }
    func archive(_ item: ChecklistItem) { act(on: item, message: "보관함으로 옮겼어요") { try $0.archive(item.id) } }
    func restore(_ item: ChecklistItem) { act(on: item, message: "할 일 목록으로 복구했어요") { try $0.restore(item.id) } }
    func changeCategory(_ item: ChecklistItem, to id: String) {
        act(on: item, message: text("카테고리를 ‘{name}’로 바꿨어요", ["name": categoryName(id)])) { try $0.setCategory(item.id, categoryID: id) }
    }
    func delete(_ items: [ChecklistItem]) {
        guard let repository, !items.isEmpty else { return }
        do {
            let removed = try repository.delete(items.map(\.id))
            document = repository.document; undoAction = .reinsert(removed)
            announce(removed.count == 1 ? text("삭제했어요") : text("항목 {count}개를 삭제했어요", ["count": String(removed.count)]))
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteCategory(_ id: String) {
        guard let repository else { return }
        do {
            let removed = try repository.deleteCategory(id)
            document = repository.document
            if categoryID == id { categoryID = nil }
            undoAction = .category(removed)
            announce(text("‘{name}’ 카테고리를 삭제했어요", ["name": removed.category.displayName(in: language)]))
        } catch { errorMessage = error.localizedDescription }
    }
    func emptyArchive() { delete(document.items.filter(\.isArchived)) }
    func undo() {
        guard let action = undoAction, let repository else { return }
        do {
            switch action {
            case .replace(let item): try repository.replace(item)
            case .reinsert(let items): try repository.reinsert(items)
            case .category(let removed): try repository.restoreCategory(removed)
            }
            document = repository.document; undoAction = nil; toast = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func add(_ request: CaptureRequest) throws {
        guard let repository else { throw CheckerError.invalid("저장소를 열 수 없어요.") }
        _ = try repository.add(request); document = repository.document; undoAction = nil; announce("할 일을 추가했어요")
    }
    func addCategory(_ name: String, color: CategoryColor) throws {
        guard let repository else { throw CheckerError.invalid("저장소를 열 수 없어요.") }
        try repository.addCategory(name: name, color: color); document = repository.document
    }
    func changeCategoryColor(_ category: TaskCategory, to color: CategoryColor) throws {
        guard let repository else { throw CheckerError.invalid("저장소를 열 수 없어요.") }
        try repository.setCategoryColor(category.id, color: color)
        document = repository.document
    }
    func changeContext(_ item: ChecklistItem, sessionName: String, projectName: String) throws {
        guard let repository else { throw CheckerError.invalid("저장소를 열 수 없어요.") }
        try repository.setContext(item.id, sessionName: sessionName, projectName: projectName)
        document = repository.document
        if case .replace(var previous) = undoAction, previous.id == item.id,
           let saved = document.items.first(where: { $0.id == item.id }) {
            previous.sessionName = saved.sessionName
            previous.projectName = saved.projectName
            undoAction = .replace(previous)
        }
    }
    func openSource(_ item: ChecklistItem) {
        guard let raw = item.sourceURL else { return }
        do {
            guard let safe = try SourceLink.validated(raw), let url = URL(string: safe) else { return }
            if item.sourceApp == .chrome, let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    if let error { Task { @MainActor in self?.errorMessage = error.localizedDescription } }
                }
            } else if !NSWorkspace.shared.open(url) { errorMessage = "이 링크를 열 앱을 찾지 못했어요. 원문 앱이 설치되어 있는지 확인해 주세요." }
        } catch { errorMessage = error.localizedDescription }
    }
    func openRelated(_ item: ChecklistItem) {
        do {
            guard let safe = try SourceLink.validatedWeb(item.relatedURL), let url = URL(string: safe) else { return }
            if !NSWorkspace.shared.open(url) { errorMessage = "이 링크를 열 앱을 찾지 못했어요. 원문 앱이 설치되어 있는지 확인해 주세요." }
        } catch { errorMessage = error.localizedDescription }
    }
    func importCaptures() {
        reloadLanguage()
        guard let repository else { return }
        do {
            let before = repository.document.items.count
            let handled = try repository.drainInbox()
            if handled > 0 {
                document = repository.document
                let added = document.items.count - before
                if added > 0 { undoAction = nil; announce(text("새 할 일 {count}개를 추가했어요", ["count": String(added)])) }
            }
        } catch {
            if errorMessage != error.localizedDescription { errorMessage = error.localizedDescription }
        }
    }
    func announce(_ text: String) {
        toastWork?.cancel(); toast = self.text(text)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil; self?.undoAction = nil }
        toastWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }
}
