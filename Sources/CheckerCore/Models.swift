import Foundation

public enum SourceApp: String, Codable, CaseIterable, Identifiable {
    case codex, claude, chrome, manual
    public var id: String { rawValue }
    public var label: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .chrome: return "Chrome"; case .manual: return "직접 추가" }
    }
    public var symbol: String {
        switch self { case .codex: return "terminal"; case .claude: return "sparkles"; case .chrome: return "globe"; case .manual: return "pencil" }
    }
}

public enum CategoryColor: String, Codable, CaseIterable, Identifiable {
    case gray, red, orange, yellow, green, teal, blue, purple
    public var id: String { rawValue }
}

public struct TaskCategory: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var color: CategoryColor?
    public init(id: String, name: String, description: String = "", color: CategoryColor? = nil) {
        self.id = id; self.name = name; self.description = description; self.color = color
    }
    public var displayColor: CategoryColor {
        if let color { return color }
        switch id {
        case "development": return .blue
        case "review": return .purple
        case "documents": return .orange
        default: return .gray
        }
    }
    public static let defaults = [
        TaskCategory(id: "development", name: "개발", description: "구현, 설계, 버그 수정, 테스트 등 개발 후속 작업"),
        TaskCategory(id: "review", name: "리뷰", description: "AI 결과, PR, 제안, 변경 내용의 검토와 의사 결정"),
        TaskCategory(id: "documents", name: "문서", description: "문서 읽기, 조사, 회의 정리와 참고 자료"),
        TaskCategory(id: "uncategorized", name: "미분류", description: "분류가 애매하거나 맥락이 부족한 항목")
    ]
}

public struct ChecklistItem: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var sourceApp: SourceApp
    public var sourceURL: String?
    public var note: String
    public var categoryID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var orderDate: Date
    public var archivedAt: Date?
    /// A related web page (ticket, PR, document), separate from `sourceURL`, which returns to the conversation.
    public var relatedURL: String? = nil
    public var sessionName: String? = nil
    public var projectName: String? = nil
    public var isArchived: Bool { archivedAt != nil }
}

public struct CaptureRequest: Codable {
    public var schemaVersion: Int
    public var requestID: String
    public var title: String
    public var sourceApp: SourceApp
    public var sourceURL: String?
    public var note: String?
    public var categoryID: String?
    public var createdAt: Date?
    public var relatedURL: String?
    public var sessionName: String?
    public var projectName: String?
    public init(requestID: String = UUID().uuidString.lowercased(), title: String, sourceApp: SourceApp = .manual, sourceURL: String? = nil, note: String? = nil, categoryID: String? = nil, createdAt: Date? = nil, relatedURL: String? = nil, sessionName: String? = nil, projectName: String? = nil) {
        self.schemaVersion = 1; self.requestID = requestID; self.title = title; self.sourceApp = sourceApp; self.sourceURL = sourceURL; self.note = note; self.categoryID = categoryID; self.createdAt = createdAt; self.relatedURL = relatedURL
        self.sessionName = sessionName; self.projectName = projectName
    }
}

public struct ChecklistDocument: Codable, Equatable {
    public var schemaVersion = 1
    public var categories = TaskCategory.defaults
    public var items: [ChecklistItem] = []
    public init() {}
}

public enum CheckerError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public enum SourceLink {
    /// Related links are web pages only.
    public static func validatedWeb(_ raw: String?) throws -> String? {
        guard let link = try validated(raw) else { return nil }
        guard let scheme = URL(string: link)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw CheckerError.invalid("관련 링크는 웹페이지 주소만 쓸 수 있어요.") }
        return link
    }
    public static func validated(_ raw: String?) throws -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard raw.utf8.count <= 8192, let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { throw CheckerError.invalid("원문 링크를 확인해 주세요.") }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { throw CheckerError.invalid("웹페이지의 전체 주소를 입력해 주세요.") }
        case "codex":
            guard url.host == "threads", url.path.count > 1, url.path != "/new" else { throw CheckerError.invalid("Codex의 해당 대화 링크를 입력해 주세요.") }
        case "claude":
            // Only the link Claude desktop uses to reopen one Claude Code session.
            guard raw.range(of: #"^claude://code/continue\?session=local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
                throw CheckerError.invalid("Claude Code 세션 링크를 확인해 주세요.")
            }
        default: throw CheckerError.invalid("https, http, Codex 대화 또는 Claude Code 세션 링크를 사용할 수 있어요.")
        }
        return raw
    }
}
