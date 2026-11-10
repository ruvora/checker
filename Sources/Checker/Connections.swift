import AppKit
import SwiftUI
import CheckerCore

struct ConnectionOutcome: Sendable {
    let succeeded: Bool
    let message: String
    let extensionFolder: String?
}

@MainActor final class ConnectionSetup: ObservableObject {
    @Published var codex = true
    @Published var chrome = true
    @Published var claude = FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    @Published var isBusy = false
    @Published var message: String?
    @Published var succeeded = false
    @Published var extensionFolder: String?

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
            if let folder = info["extensionFolder"] as? String { extensionFolder = folder }
        }
    }
    func install(language: String) {
        guard !isBusy, let resources = Bundle.main.resourceURL else { return }
        isBusy = true; message = nil; succeeded = false
        let app = Bundle.main.bundleURL.path
        var arguments = ["-I", "-B", resources.appendingPathComponent("capture/install_connections.py").path, "--app-bundle", app, "--language", language]
        if codex { arguments.append("--codex") }
        if chrome { arguments.append("--chrome") }
        if claude { arguments.append("--claude") }
        let command = resources.appendingPathComponent("python/bin/python3").path
        Task {
            let outcome = await Task.detached { Self.run(command: command, arguments: arguments) }.value
            self.isBusy = false
            self.succeeded = outcome.succeeded
            self.message = outcome.message
            self.extensionFolder = outcome.extensionFolder ?? self.extensionFolder
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
            VStack(alignment: .leading, spacing: 12) {
                Toggle(model.text("Codex · 후속 작업을 추가하는 스킬"), isOn: $setup.codex)
                Toggle(model.text("Chrome · 현재 화면을 AI로 정리해 추가"), isOn: $setup.chrome)
                Toggle(model.text("Claude 데스크톱 · Checker 도구 연결"), isOn: $setup.claude)
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
                    .disabled(setup.isBusy || !ConnectionSetup.isDistribution || !(setup.codex || setup.chrome || setup.claude))
                if setup.isBusy { ProgressView().controlSize(.small) }
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
        }.padding(26).frame(width: 460).background(Palette.background).tint(Palette.accent)
    }
}
