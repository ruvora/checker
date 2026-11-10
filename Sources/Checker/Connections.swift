import AppKit
import SwiftUI
import CheckerCore

struct ConnectionOutcome: Sendable {
    let succeeded: Bool
    let message: String
    let extensionFolder: String?
}

enum ConnectionState { case connected, attention, missing }

struct ConnectionStatus: Identifiable {
    let id: String
    let name: String
    let state: ConnectionState
    var detail: String = ""
    var parameters: [String: String] = [:]
}

@MainActor final class ConnectionSetup: ObservableObject {
    @Published var statuses: [ConnectionStatus] = []
    @Published var codex = true
    @Published var chrome = true
    @Published var claude = FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    @Published var claudeCode = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json").path)
    @Published var isBusy = false
    @Published var message: String?
    @Published var succeeded = false
    @Published var extensionFolder: String?
    /// Set when Claude desktop must be quit first. A running Claude rewrites its config and drops a new MCP entry.
    @Published var needsClaudeQuit = false
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static var runningClaude: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).filter { !$0.isTerminated }
    }

    static var runtime: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Checker/runtime")
    }
    static var isDistribution: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("python/bin/python3").path)
    }
    static var needsSetup: Bool {
        guard isDistribution else { return false }
        guard let data = try? Data(contentsOf: runtime.appendingPathComponent("connections.json")),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return info["appPath"] as? String != Bundle.main.bundleURL.path ||
            info["version"] as? String != Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    init() {
        if let data = try? Data(contentsOf: Self.runtime.appendingPathComponent("connections.json")),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            claude = (info["claude"] as? Bool ?? false) || claude
            claudeCode = (info["claudeCode"] as? Bool ?? false) || claudeCode
            if let folder = info["extensionFolder"] as? String { extensionFolder = folder }
        }
    }
    func install(language: String) {
        guard !isBusy else { return }
        if claude && !Self.runningClaude.isEmpty {
            needsClaudeQuit = true; succeeded = false
            message = "Claude 데스크톱이 실행 중이에요. 실행 중에 설치하면 Claude가 설정을 다시 저장하면서 연결이 사라질 수 있어요."
            return
        }
        needsClaudeQuit = false
        run(language: language, reopen: nil)
    }
    /// Quits Claude desktop, installs, then opens Claude again so it loads the new connection.
    func quitClaudeAndInstall(language: String) {
        guard !isBusy else { return }
        let apps = Self.runningClaude
        let claudeURL = apps.first?.bundleURL
        isBusy = true; needsClaudeQuit = false; message = "Claude를 종료하는 중…"; succeeded = false
        apps.forEach { $0.terminate() }
        Task {
            for _ in 0..<40 where !Self.runningClaude.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            self.isBusy = false
            guard Self.runningClaude.isEmpty else {
                self.needsClaudeQuit = true
                self.message = "Claude가 종료되지 않았어요. ⌘Q로 직접 종료한 뒤 다시 설치해 주세요."
                return
            }
            self.run(language: language, reopen: claudeURL)
        }
    }
    private func run(language: String, reopen claudeURL: URL?) {
        guard let resources = Bundle.main.resourceURL else { return }
        isBusy = true; message = nil; succeeded = false
        let app = Bundle.main.bundleURL.path
        var arguments = ["-I", "-B", resources.appendingPathComponent("capture/install_connections.py").path, "--app-bundle", app, "--language", language]
        if codex { arguments.append("--codex") }
        if chrome { arguments.append("--chrome") }
        if claude { arguments.append("--claude") }
        if claudeCode { arguments.append("--claude-code") }
        let command = resources.appendingPathComponent("python/bin/python3").path
        Task {
            let outcome = await Task.detached { Self.run(command: command, arguments: arguments) }.value
            self.isBusy = false
            self.succeeded = outcome.succeeded
            self.message = outcome.message
            self.extensionFolder = outcome.extensionFolder ?? self.extensionFolder
            if let claudeURL {
                // Reopen even after a failed install: the user did not ask to keep Claude closed.
                NSWorkspace.shared.openApplication(at: claudeURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                if outcome.succeeded { self.message = "연결 파일을 설치하고 Claude를 다시 열었어요. 아래에서 Chrome 확장을 추가해 주세요." }
            }
        }
    }
    nonisolated private static func run(command: String, arguments: [String]) -> ConnectionOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let success = process.terminationStatus == 0 && info["status"] as? String == "ok"
                return ConnectionOutcome(succeeded: success,
                    message: success ? "연결 파일을 설치했어요. 아래에서 Chrome 확장을 추가하고, Claude를 다시 시작해 주세요." : info["message"] as? String ?? "연결을 설치하지 못했어요.",
                    extensionFolder: info["extensionFolder"] as? String)
            }
            return ConnectionOutcome(succeeded: false, message: "연결을 설치하지 못했어요. 앱을 응용 프로그램 폴더로 옮긴 뒤 다시 열어 주세요.", extensionFolder: nil)
        } catch {
            return ConnectionOutcome(succeeded: false, message: "실행 환경을 열지 못했어요. 배포용 Checker 앱을 다시 설치해 주세요.", extensionFolder: nil)
        }
    }
    /// Reads what is actually installed on disk, not only what the last install reported.
    func refreshStatus(dataDirectory: URL, locale: Locale) {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let runtime = Self.runtime
        func json(_ url: URL) -> [String: Any]? {
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func exists(_ url: URL) -> Bool { (try? files.attributesOfItem(atPath: url.path)) != nil }

        var codex = ConnectionStatus(id: "codex", name: "Codex 스킬", state: .missing)
        let skill = home.appendingPathComponent(".codex/skills/checker-capture")
        if exists(skill) {
            let target = runtime.appendingPathComponent("skills/checker-capture")
            let ours = skill.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path &&
                files.fileExists(atPath: target.appendingPathComponent("SKILL.md").path)
            codex = ConnectionStatus(id: "codex", name: codex.name, state: ours ? .connected : .attention,
                detail: ours ? "새 대화에서 $checker-capture로 사용할 수 있어요." : "다른 checker-capture 스킬이 있어 그대로 두었어요.")
        }

        var chrome = ConnectionStatus(id: "chrome", name: "Chrome 확장", state: .missing)
        let host = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/local.checker.capture.json")
        if exists(host) {
            let launcher = runtime.appendingPathComponent("native-host").path
            if json(host)?["path"] as? String != launcher || !files.isExecutableFile(atPath: launcher) {
                chrome = ConnectionStatus(id: "chrome", name: chrome.name, state: .attention, detail: "다른 Chrome 연결이 있어 그대로 두었어요.")
            } else if let seen = (try? files.attributesOfItem(atPath: dataDirectory.appendingPathComponent("chrome-last-seen").path))?[.modificationDate] as? Date {
                let formatter = RelativeDateTimeFormatter(); formatter.locale = locale
                chrome = ConnectionStatus(id: "chrome", name: chrome.name, state: .connected, detail: "확장이 연결됐어요. 마지막 사용: {time}",
                    parameters: ["time": formatter.localizedString(for: min(seen, Date()), relativeTo: Date())])
            } else {
                chrome = ConnectionStatus(id: "chrome", name: chrome.name, state: .attention, detail: "연결 파일은 있어요. Chrome 확장을 추가한 뒤 팝업을 한 번 열어 주세요.")
            }
        }

        var claude = ConnectionStatus(id: "claude", name: "Claude 데스크톱", state: .missing)
        let config = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        if let entry = (json(config)?["mcpServers"] as? [String: Any])?["checker"] {
            let args = (entry as? [String: Any])?["args"] as? [String]
            if args?.first != runtime.appendingPathComponent("checker_bridge.py").path {
                claude = ConnectionStatus(id: "claude", name: claude.name, state: .attention, detail: "다른 checker 연결이 있어 그대로 두었어요.")
            } else {
                // Claude loads MCP servers at launch, so a Claude started before Checker installed the entry lacks the tool.
                // Compare with the install time, not the config's modification time: Claude rewrites that file itself.
                let installed = (json(runtime.appendingPathComponent("connections.json"))?["claudeInstalledAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                let launched = Self.runningClaude.first?.launchDate
                let stale = launched != nil && installed != nil && launched! < installed!
                claude = ConnectionStatus(id: "claude", name: claude.name, state: stale ? .attention : .connected,
                    detail: stale ? "Claude를 다시 시작해야 checker 도구가 나타나요." : "Claude에서 checker 도구를 쓸 수 있어요.")
            }
        }
        var claudeCode = ConnectionStatus(id: "claudeCode", name: "Claude Code", state: .missing)
        if let entry = (json(home.appendingPathComponent(".claude.json"))?["mcpServers"] as? [String: Any])?["checker"] {
            let ours = ((entry as? [String: Any])?["args"] as? [String])?.first == runtime.appendingPathComponent("checker_bridge.py").path
            // Claude Code loads MCP servers when a session starts, so only new sessions see the change.
            claudeCode = ConnectionStatus(id: "claudeCode", name: claudeCode.name, state: ours ? .connected : .attention,
                detail: ours ? "새 Claude Code 세션에서 checker 도구를 쓸 수 있어요." : "다른 Claude Code checker 연결이 있어 보존했습니다. 기존 연결을 확인해 주세요.")
        }
        statuses = [codex, chrome, claude, claudeCode]
    }
    func revealExtension() {
        guard let extensionFolder else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: extensionFolder)
    }
    func copyExtensionPath() {
        guard let extensionFolder else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(extensionFolder, forType: .string)
    }
}

struct ConnectionsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var setup = ConnectionSetup()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "checklist").font(.system(size: 25)).foregroundColor(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.text("Checker 연결 설정")).font(.system(size: 21, weight: .semibold))
                    Text(model.text("나중에 챙길 일을 한곳으로 모으세요.")).font(.system(size: 12)).foregroundColor(Palette.muted)
                }
            }
            Picker(model.text("언어"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                ForEach(AppLanguage.allCases) { language in Text(language.label).tag(language) }
            }.disabled(setup.isBusy)
            Text(model.text("앱·확장·AI 결과에 적용됩니다.")).font(.system(size: 11)).foregroundColor(Palette.muted)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.text("연결 상태")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundColor(Palette.muted)
                        .help(model.text("상태 새로고침")).accessibilityLabel(model.text("상태 새로고침"))
                }
                ForEach(setup.statuses) { status in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(status.state)).foregroundColor(color(status.state)).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.text(status.name)).font(.system(size: 12, weight: .medium))
                                Text(model.text(label(status.state))).font(.system(size: 11)).foregroundColor(color(status.state))
                            }
                            if !status.detail.isEmpty {
                                Text(model.text(status.detail, status.parameters)).font(.system(size: 11)).foregroundColor(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Toggle(model.text("Codex · 후속 작업을 추가하는 스킬"), isOn: $setup.codex)
                Toggle(model.text("Chrome · 현재 화면을 AI로 정리해 추가"), isOn: $setup.chrome)
                Toggle(model.text("Claude 데스크톱 · Checker 도구 연결"), isOn: $setup.claude)
                Toggle(model.text("Claude Code · 모든 프로젝트에 Checker 도구 연결"), isOn: $setup.claudeCode)
            }.toggleStyle(.checkbox).disabled(setup.isBusy)
            Text(model.text("Chrome AI 분석은 로그인된 Codex 앱을 사용합니다. 화면 이미지와 페이지 내용을 보내 제목·메모·카테고리를 정리합니다."))
                .font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if !ConnectionSetup.isDistribution {
                Text(model.text("이 화면의 자동 설치는 배포용 앱에서 사용할 수 있어요. 개발 환경에서는 설치 스크립트를 실행해 주세요."))
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
            }
            HStack {
                Button(model.text(setup.isBusy ? "설치 중…" : "선택한 연결 설치")) { setup.install(language: model.language.rawValue) }
                    .buttonStyle(.borderedProminent)
                    .disabled(setup.isBusy || !ConnectionSetup.isDistribution || !(setup.codex || setup.chrome || setup.claude || setup.claudeCode))
                if setup.isBusy { ProgressView().controlSize(.small) }
            }
            if setup.needsClaudeQuit {
                HStack {
                    Button(model.text("Claude 종료 후 설치")) { setup.quitClaudeAndInstall(language: model.language.rawValue) }
                    Text(model.text("설치가 끝나면 Claude를 다시 열어요. Claude에서 진행 중인 작업은 먼저 저장해 주세요."))
                        .font(.system(size: 11)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = setup.message {
                Text(model.text(message)).font(.system(size: 12)).foregroundColor(setup.succeeded ? Palette.accent : .red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if setup.extensionFolder != nil {
                Divider()
                Text(model.text("Chrome 확장 추가")).font(.system(size: 13, weight: .semibold))
                Text(model.text("Chrome에서 chrome://extensions 를 열고, 개발자 모드 → ‘압축해제된 확장 프로그램을 로드합니다’를 선택하세요. 아래 폴더를 선택하면 됩니다. 이미 설치했다면 기존 Checker 확장을 새로고침하세요."))
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack {
                    Button(model.text("확장 폴더 열기")) { setup.revealExtension() }
                    Button(model.text("폴더 경로 복사")) { setup.copyExtensionPath() }
                }
                Text(model.text("Claude는 다시 시작한 뒤 checker 도구를 켜 주세요. Codex 스킬은 새 대화에서 사용할 수 있어요."))
                    .font(.system(size: 11)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack { Spacer(); Button(model.text("닫기")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(setup.isBusy) }
        }.padding(26).frame(width: 460).background(DragArea()).background(Palette.background).tint(Palette.accent)
        .onAppear { refresh() }
        .onChange(of: setup.isBusy) { busy in if !busy { refresh() } }
        .onChange(of: model.language) { _ in refresh() }
        // Coming back from Chrome or Claude should show the new state without pressing refresh.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    private func refresh() { setup.refreshStatus(dataDirectory: model.dataDirectory, locale: model.language.locale) }
    private func icon(_ state: ConnectionState) -> String {
        switch state { case .connected: "checkmark.circle.fill"; case .attention: "exclamationmark.circle.fill"; case .missing: "circle" }
    }
    private func color(_ state: ConnectionState) -> Color {
        switch state { case .connected: Palette.accent; case .attention: .orange; case .missing: Palette.muted }
    }
    private func label(_ state: ConnectionState) -> String {
        switch state { case .connected: "연결됨"; case .attention: "확인 필요"; case .missing: "설치 안 됨" }
    }
}
