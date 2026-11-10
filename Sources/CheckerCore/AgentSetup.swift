import Foundation
import Darwin

public struct AgentSetupRequest {
    public let id: String
    public let home: URL
    public let connections: [String]
    public let language: AppLanguage?
    public let dataDirectory: URL
    public var receiptURL: URL { dataDirectory.appendingPathComponent("installations/\(id).json") }
    public static func pendingURL(in directory: URL) -> URL { directory.appendingPathComponent("installations/pending.json") }

    public static func loadPending(in directory: URL, now: Date = Date()) throws -> AgentSetupRequest? {
        let file = pendingURL(in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else { return nil }
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              value["schemaVersion"] as? Int == 1,
              let created = value["createdAt"] as? TimeInterval,
              now.timeIntervalSince1970 - created >= -300, now.timeIntervalSince1970 - created < 3600,
              let id = value["requestID"] as? String, let home = value["home"] as? String,
              let connections = value["connections"] as? String else { return nil }
        var arguments = ["Checker", "--agent-setup", id, "--connections", connections, "--setup-home", home]
        if let language = value["language"] as? String, language != "auto" { arguments += ["--setup-language", language] }
        return try parse(arguments, dataDirectory: directory)
    }

    public func clearPending() throws {
        let file = Self.pendingURL(in: dataDirectory)
        guard let data = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (value["requestID"] as? String)?.lowercased() == id else { return }
        try FileManager.default.removeItem(at: file)
    }

    public static func parse(_ arguments: [String], dataDirectory: URL, defaultHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> AgentSetupRequest? {
        guard arguments.contains("--agent-setup") else { return nil }
        func value(_ key: String) throws -> String {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                throw CheckerError.invalid("Missing agent setup argument: \(key)")
            }
            return arguments[index + 1]
        }
        guard let uuid = UUID(uuidString: try value("--agent-setup")) else { throw CheckerError.invalid("Invalid setup request ID.") }
        let selected = try value("--connections")
        let connections = selected == "none" ? [] : selected.split(separator: ",").map(String.init)
        guard Set(connections).isSubset(of: ["codex", "chrome", "claude"]) else { throw CheckerError.invalid("Unknown Checker connection.") }
        var home = defaultHome
        if arguments.contains("--setup-home") {
            let path = try value("--setup-home")
            guard path.hasPrefix("/"), path != "/" else { throw CheckerError.invalid("Invalid installation home.") }
            home = URL(fileURLWithPath: path, isDirectory: true)
        }
        let expected = home.appendingPathComponent("Library/Application Support/Checker").standardizedFileURL.resolvingSymlinksInPath()
        guard dataDirectory.standardizedFileURL.resolvingSymlinksInPath() == expected else {
            throw CheckerError.invalid("Agent setup and checklist data must use the same installation home.")
        }
        var language: AppLanguage?
        if arguments.contains("--setup-language") {
            guard let supported = AppLanguage(rawValue: try value("--setup-language")) else { throw CheckerError.invalid("Unsupported setup language.") }
            language = supported
        }
        return AgentSetupRequest(id: uuid.uuidString.lowercased(), home: home.standardizedFileURL,
                                 connections: Array(Set(connections)).sorted(), language: language, dataDirectory: dataDirectory)
    }

    public func writeReceipt(status: String, app: URL, version: String, language: AppLanguage, message: String? = nil, extensionFolder: String? = nil) throws {
        var actions: [String] = []
        if connections.contains("chrome") { actions.append("chrome_extension_add_or_reload") }
        if connections.contains("claude") { actions.append("restart_claude_and_enable_checker_tools") }
        if connections.contains("codex") || connections.contains("chrome") { actions.append("codex_sign_in_if_needed") }
        var value: [String: Any] = ["schemaVersion": 1, "requestID": id, "status": status,
            "appPath": app.path, "version": version, "language": language.rawValue,
            "connectionsRegistered": status == "configured" ? connections : [],
            "remainingActions": status == "configured" ? actions : [], "updatedAt": Date().timeIntervalSince1970]
        if let message { value["message"] = language.text(message) }
        if let extensionFolder { value["extensionFolder"] = extensionFolder }
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }
}
