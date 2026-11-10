import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en", korean = "ko"
    public var id: String { rawValue }
    public var label: String { self == .english ? "English" : "한국어" }
    public var locale: Locale { Locale(identifier: rawValue) }
    public static func preferred(_ languages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for language in languages {
            let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let code, let supported = AppLanguage(rawValue: code) { return supported }
        }
        return .english
    }
    public func text(_ message: String, _ parameters: [String: String] = [:]) -> String {
        let key = Translations.english.first(where: { $0.value == message })?.key ?? message
        var result = self == .english ? Translations.english[key] ?? message : key
        for (name, value) in parameters { result = result.replacingOccurrences(of: "{\(name)}", with: value) }
        return result
    }
}

public struct LanguageSettings {
    public let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("settings.json") }
    public func load() throws -> AppLanguage {
        guard FileManager.default.fileExists(atPath: file.path) else { return .preferred() }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw CheckerError.invalid("언어 설정을 읽지 못했어요. 설정 파일을 확인해 주세요.")
        }
        guard let value = object["language"] else { return .preferred() }
        guard let raw = value as? String, let language = AppLanguage(rawValue: raw) else {
            throw CheckerError.invalid("한국어 또는 영어를 선택해 주세요.")
        }
        return language
    }
    public func save(_ language: AppLanguage) throws {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                throw CheckerError.invalid("언어 설정을 읽지 못했어요. 설정 파일을 확인해 주세요.")
            }
            object = existing
        }
        object["language"] = language.rawValue
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public extension TaskCategory {
    func displayName(in language: AppLanguage) -> String {
        guard let standard = Self.defaults.first(where: { $0.id == id }),
              name == standard.name || name == AppLanguage.english.text(standard.name) else { return name }
        return language.text(standard.name)
    }
}
