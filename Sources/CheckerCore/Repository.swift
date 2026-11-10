import Foundation

public final class ChecklistRepository {
    public let directory: URL
    public let documentURL: URL
    public private(set) var document: ChecklistDocument
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["CHECKER_DATA_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Checker", isDirectory: true)
    }

    public init(directory: URL = ChecklistRepository.defaultDirectory) throws {
        self.directory = directory
        documentURL = directory.appendingPathComponent("checklist.json")
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        for folder in [directory, directory.appendingPathComponent("inbox"), directory.appendingPathComponent("receipts"), directory.appendingPathComponent("failed")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if FileManager.default.fileExists(atPath: documentURL.path) {
            document = try decoder.decode(ChecklistDocument.self, from: Data(contentsOf: documentURL))
            guard document.schemaVersion == 1 else { throw CheckerError.invalid("이 데이터는 더 새로운 Checker 버전에서 만들어졌어요.") }
            guard Set(document.items.map(\.id)).count == document.items.count else { throw CheckerError.invalid("중복된 항목 ID가 있어 데이터 확인이 필요해요.") }
        } else {
            document = ChecklistDocument()
            try persist(document)
        }
    }

    private func persist(_ value: ChecklistDocument) throws {
        let data = try encoder.encode(value)
        try data.write(to: documentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: documentURL.path)
    }

    private func commit(_ change: (inout ChecklistDocument) throws -> Void) throws {
        var next = document
        try change(&next)
        try persist(next)
        document = next
    }

    @discardableResult public func add(_ request: CaptureRequest, now: Date = Date()) throws -> ChecklistItem {
        guard request.schemaVersion == 1, UUID(uuidString: request.requestID) != nil else { throw CheckerError.invalid("등록 요청 형식이 올바르지 않아요.") }
        let id = request.requestID.lowercased()
        if let existing = document.items.first(where: { $0.id == id }) { return existing }
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 300 else { throw CheckerError.invalid("할 일을 300자 이내로 적어 주세요.") }
        let link = try SourceLink.validated(request.sourceURL)
        guard (request.note ?? "").count <= 8000 else { throw CheckerError.invalid("메모가 너무 길어요. 8,000자 이내로 줄여 주세요.") }
        let category = document.categories.contains(where: { $0.id == request.categoryID }) ? request.categoryID! : "uncategorized"
        let item = ChecklistItem(id: id, title: title, sourceApp: request.sourceApp, sourceURL: link, note: request.note ?? "", categoryID: category, createdAt: request.createdAt ?? now, updatedAt: now, orderDate: now, archivedAt: nil)
        try commit { $0.items.append(item) }
        return item
    }

    public func archive(_ id: String, now: Date = Date()) throws { try update(id) { $0.archivedAt = now; $0.updatedAt = now } }
    public func restore(_ id: String, now: Date = Date()) throws { try update(id) { $0.archivedAt = nil; $0.updatedAt = now; $0.orderDate = now } }
    public func setCategory(_ id: String, categoryID: String) throws {
        guard document.categories.contains(where: { $0.id == categoryID }) else { throw CheckerError.invalid("카테고리를 찾을 수 없어요.") }
        try update(id) { $0.categoryID = categoryID; $0.updatedAt = Date() }
    }
    public func replace(_ item: ChecklistItem) throws { try update(item.id) { $0 = item } }
    private func update(_ id: String, change: (inout ChecklistItem) -> Void) throws {
        try commit { doc in
            guard let index = doc.items.firstIndex(where: { $0.id == id }) else { throw CheckerError.invalid("항목을 찾을 수 없어요.") }
            change(&doc.items[index])
        }
    }

    public func addCategory(name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 20 else { throw CheckerError.invalid("카테고리 이름을 20자 이내로 적어 주세요.") }
        guard !document.categories.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw CheckerError.invalid("같은 이름의 카테고리가 있어요.") }
        try commit { $0.categories.insert(TaskCategory(id: "custom-" + UUID().uuidString.lowercased(), name: name), at: max(0, $0.categories.count - 1)) }
    }

    @discardableResult public func drainInbox() throws -> Int {
        let inbox = directory.appendingPathComponent("inbox")
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var imported = 0
        for file in files {
            var request: CaptureRequest?
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= 128 * 1024 else { throw CheckerError.invalid("등록 요청이 너무 커요.") }
                let decoded = try decoder.decode(CaptureRequest.self, from: data)
                request = decoded
                let item = try add(decoded)
                let receipt: [String: Any] = ["status": "added", "id": item.id, "categoryID": item.categoryID]
                try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent("receipts/\(item.id).json"), options: .atomic)
                try FileManager.default.removeItem(at: file)
                imported += 1
            } catch {
                // Retry filesystem failures; quarantine invalid requests without blocking the queue.
                if error is DecodingError || error is CheckerError {
                    let name = file.lastPathComponent
                    let destination = directory.appendingPathComponent("failed/\(UUID().uuidString)-\(name)")
                    try FileManager.default.moveItem(at: file, to: destination)
                    let id = request?.requestID.lowercased() ?? file.deletingPathExtension().lastPathComponent
                    if UUID(uuidString: id) != nil {
                        let receipt = ["status": "error", "message": error.localizedDescription]
                        try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent("receipts/\(id).json"), options: .atomic)
                    }
                } else { throw error }
            }
        }
        return imported
    }
}
