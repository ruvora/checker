import AppKit
import SwiftUI
import CheckerCore

final class CheckerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CheckerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct WindowPreferences: Codable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var pinned: Bool; var collapsed: Bool
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: CheckerPanel!
    var model: AppModel!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var mainFrame = NSRect.zero
    var geometryWork: DispatchWorkItem?
    var changingFrame = false
    var preferencesURL: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        var directory = ChecklistRepository.defaultDirectory
        if let index = CommandLine.arguments.firstIndex(of: "--data-dir"), CommandLine.arguments.indices.contains(index + 1) { directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true) }
        model = AppModel(directory: directory)
        preferencesURL = directory.appendingPathComponent("window.json")
        let preferences = (try? Data(contentsOf: preferencesURL)).flatMap { try? JSONDecoder().decode(WindowPreferences.self, from: $0) }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let initial = NSRect(x: visible.maxX - 420, y: visible.minY + 80, width: 390, height: 520)
        panel = CheckerPanel(contentRect: initial, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Checker"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(type)?.isHidden = true }
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 300, height: 340)
        panel.maxSize = NSSize(width: 900, height: 1000)
        panel.contentView = CheckerHostingView(rootView: ChecklistView(model: model).ignoresSafeArea())
        if let p = preferences, p.width.isFinite, p.height.isFinite, p.x.isFinite, p.y.isFinite {
            var saved = NSRect(x: p.x, y: p.y, width: min(900, max(300, p.width)), height: min(1000, max(340, p.height)))
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved.insetBy(dx: 40, dy: 40)) }) { saved.origin = initial.origin }
            panel.setFrame(saved, display: false); model.isPinned = p.pinned
        }
        mainFrame = panel.frame
        panel.level = model.isPinned ? .floating : .normal
        panel.delegate = self
        model.onPin = { [weak self] pinned in self?.panel.level = pinned ? .floating : .normal; self?.saveGeometry() }
        model.onCollapse = { [weak self] in self?.toggleCollapsed() }
        model.onLanguageChange = { [weak self] in self?.installMenu() }
        installMenu()
        model.importCaptures()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in Task { @MainActor in self?.model.importCaptures() } }
        if preferences?.collapsed == true { toggleCollapsed() }
        panel.orderFrontRegardless()
        if ConnectionSetup.needsSetup {
            if model.isCollapsed { toggleCollapsed() }
            model.showConnections = true
            showWindow()
        }
    }
    func installMenu() {
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Checker")
        let menu = NSMenu()
        let show = menu.addItem(withTitle: model.text("체크리스트 열기"), action: #selector(showWindow), keyEquivalent: ""); show.target = self
        let add = menu.addItem(withTitle: model.text("할 일 추가"), action: #selector(addItem), keyEquivalent: ""); add.target = self
        let connections = menu.addItem(withTitle: model.text("연결 설정…"), action: #selector(showConnections), keyEquivalent: ","); connections.target = self
        menu.addItem(.separator())
        let folder = menu.addItem(withTitle: model.text("데이터 폴더 열기"), action: #selector(openData), keyEquivalent: ""); folder.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: model.text("Checker 종료"), action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
    }
    @objc func showWindow() { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func addItem() { if model.isCollapsed { toggleCollapsed() }; showWindow(); model.showAdd = true }
    @objc func showConnections() { if model.isCollapsed { toggleCollapsed() }; showWindow(); model.showConnections = true }
    @objc func openData() { NSWorkspace.shared.open(model.dataDirectory) }
    @objc func quitApp() { saveGeometry(); NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { panel.orderFrontRegardless(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { panel.orderOut(nil); return false }
    func toggleCollapsed() {
        changingFrame = true
        if !model.isCollapsed {
            mainFrame = panel.frame
            model.isCollapsed = true
            panel.minSize = NSSize(width: 190, height: 68)
            panel.setFrame(NSRect(x: mainFrame.maxX - 220, y: mainFrame.minY, width: 220, height: 72), display: true)
        } else {
            let right = panel.frame.maxX, bottom = panel.frame.minY
            model.isCollapsed = false
            panel.minSize = NSSize(width: 300, height: 340)
            mainFrame.origin = CGPoint(x: right - mainFrame.width, y: bottom)
            panel.setFrame(mainFrame, display: true)
        }
        changingFrame = false; saveGeometry()
    }
    func windowDidResize(_ notification: Notification) { queueGeometrySave() }
    func windowDidMove(_ notification: Notification) { queueGeometrySave() }
    func queueGeometrySave() {
        guard !changingFrame else { return }
        geometryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveGeometry() }
        geometryWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func saveGeometry() {
        guard panel != nil, model != nil, !changingFrame else { return }
        if !model.isCollapsed { mainFrame = panel.frame }
        let frame = mainFrame
        let value = WindowPreferences(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height, pinned: model.isPinned, collapsed: model.isCollapsed)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: preferencesURL, options: .atomic) }
    }
    func applicationWillTerminate(_ notification: Notification) { saveGeometry(); timer?.invalidate() }
}

if CommandLine.arguments.contains("--import-only") {
    do {
        var directory = ChecklistRepository.defaultDirectory
        if let index = CommandLine.arguments.firstIndex(of: "--data-dir"), CommandLine.arguments.indices.contains(index + 1) { directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true) }
        let repository = try ChecklistRepository(directory: directory)
        let imported = try repository.drainInbox()
        let result: [String: Any] = ["status": "ok", "imported": imported, "activeCount": repository.document.items.filter { !$0.isArchived }.count, "archivedCount": repository.document.items.filter(\.isArchived).count]
        print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
