import AppKit
import SwiftUI
import CheckerCore

enum Palette {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
    static let background = color(0xFBFAF7, 0x242522)
    static let soft = color(0xF0F1E9, 0x30332B)
    static let accent = color(0x537148, 0xB1CE9E)
    static let selected = color(0xEAF0E3, 0x35412E)
    static let line = color(0xE5E7DD, 0x3C4037)
    static let muted = color(0x72766B, 0xAEB4A6)
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 350, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width, height: y + lineHeight), points)
    }
}

struct DragArea: NSViewRepresentable {
    final class DragView: NSView {
        private var dragStart: (mouse: NSPoint, origin: NSPoint)?
        // A sheet cannot move by itself, so dragging inside one moves its parent window (the sheet follows).
        override func mouseDown(with event: NSEvent) {
            guard let parent = window?.sheetParent else { window?.performDrag(with: event); return }
            dragStart = (NSEvent.mouseLocation, parent.frame.origin)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart, let parent = window?.sheetParent else { return }
            let mouse = NSEvent.mouseLocation
            parent.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
        }
        override func mouseUp(with event: NSEvent) { dragStart = nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ChecklistView: View {
    @ObservedObject var model: AppModel
    @State private var confirmEmpty = false
    @State private var categoryToDelete: TaskCategory?
    @State private var categoryToRecolor: TaskCategory?
    @State private var reviewPeriod: ReviewPeriod = .week
    @State private var reviewDate = Date()
    var body: some View {
        Group {
            if model.isCollapsed { compact }
            else { full }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .tint(Palette.accent)
        .environment(\.locale, model.language.locale)
        .confirmationDialog(model.text("‘{name}’ 카테고리를 삭제할까요?", ["name": categoryToDelete?.displayName(in: model.language) ?? ""]),
                            isPresented: Binding(get: { categoryToDelete != nil }, set: { if !$0 { categoryToDelete = nil } })) {
            Button(model.text("카테고리 삭제"), role: .destructive) { if let category = categoryToDelete { model.deleteCategory(category.id) }; categoryToDelete = nil }
            Button(model.text("취소"), role: .cancel) { categoryToDelete = nil }
        } message: {
            let count = model.document.items.filter { $0.categoryID == categoryToDelete?.id }.count
            Text(count > 0 ? model.text("이 카테고리의 항목 {count}개는 미분류로 옮겨요. 항목은 지워지지 않아요.", ["count": String(count)]) : model.text("이 카테고리에는 항목이 없어요."))
        }
        .sheet(isPresented: $model.showAdd) { AddItemView(model: model) }
        .sheet(isPresented: $model.showCategoryEditor) { CategoryEditor(model: model) }
        .sheet(item: $categoryToRecolor) { CategoryEditor(model: model, category: $0) }
        .sheet(item: $model.contextItem) { TaskContextEditor(model: model, item: $0) }
        .sheet(isPresented: $model.showConnections) { ConnectionsView(model: model) }
        .sheet(item: $model.noteItem) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text(item.title).font(.headline)
                ScrollView { Text(item.note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button(model.text("닫기")) { model.noteItem = nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 380, height: 300)
        }
        .alert(model.text("확인해 주세요"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(model.text("확인")) { model.errorMessage = nil }
        } message: { Text(model.text(model.errorMessage ?? "")) }
    }
    private var compact: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist").foregroundColor(Palette.accent).font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) { Text("Checker").font(.system(size: 12, weight: .medium)); Text(model.text("챙길 일")).font(.system(size: 10)).foregroundColor(Palette.muted) }
            Spacer(minLength: 0)
            Text("\(model.activeCount)").font(.system(size: 12, weight: .medium)).padding(6).background(Palette.selected).clipShape(RoundedRectangle(cornerRadius: 7))
            Button { model.onCollapse?() } label: {
                Image(systemName: "chevron.up").frame(width: 30, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).help(model.text("체크리스트 펼치기")).accessibilityLabel(model.text("체크리스트 펼치기"))
        }.padding(.horizontal, 16).background(DragArea())
    }
    private var full: some View {
        VStack(spacing: 0) {
            header
            // Buttons keep their full size; when the window is narrow the row wraps onto a second line.
            FlowLayout(spacing: 6) {
                scopeButton(model.text("할 일"), symbol: "checklist", count: model.activeCount, scope: .active)
                scopeButton(model.text("보관함"), symbol: "archivebox", count: model.archiveCount, scope: .archive)
                scopeButton(model.text("돌아보기"), symbol: "calendar", scope: .review)
                appButton(name: "Codex", bundleID: "com.openai.codex")
                appButton(name: "Claude", bundleID: "com.anthropic.claudefordesktop")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17).padding(.bottom, 12)
            if model.scope != .review {
                FlowLayout {
                    categoryButton(model.text("전체"))
                    ForEach(model.document.categories) { category in
                        categoryButton(category.displayName(in: model.language), category: category)
                    }
                    Button { model.showCategoryEditor = true } label: { Image(systemName: "plus").font(.system(size: 10)).padding(6) }
                        .buttonStyle(.plain).foregroundColor(Palette.muted).help(model.text("카테고리 추가")).accessibilityLabel(model.text("카테고리 추가"))
                }.padding(.horizontal, 17).padding(.bottom, 13)
            }
            if let error = model.fatalError {
                ScrollView { VStack(spacing: 16) { Image(systemName: "exclamationmark.triangle"); Text(model.text(error)).font(.system(size: 12)); Button(model.text("데이터 폴더 열기")) { NSWorkspace.shared.open(model.dataDirectory) } }.padding(20) }
            } else if model.scope == .review {
                ReviewView(model: model, period: $reviewPeriod, date: $reviewDate)
            } else if model.visibleItems.isEmpty { empty }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(model.visibleItems) { item in itemRow(item) } }.padding(.horizontal, 18)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let toast = model.toast {
                HStack(spacing: 8) {
                    Text(toast).font(.system(size: 11)).lineLimit(2)
                    Spacer(minLength: 5)
                    if model.undoAction != nil { Button(model.text("되돌리기")) { model.undo() }.buttonStyle(.plain).font(.system(size: 11)).underline() }
                }.padding(.horizontal, 17).padding(.vertical, 9).background(Palette.selected)
            }
            footer
        }
    }
    private var header: some View {
        HStack(spacing: 9) {
            DragArea().frame(height: 32).overlay(alignment: .leading) {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").font(.system(size: 14)).foregroundColor(Palette.accent).frame(width: 28, height: 28).background(Palette.selected).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("CHECKER").font(.system(size: 11, weight: .semibold)).tracking(1.5)
                }.allowsHitTesting(false)
            }
            Button { model.showConnections = true } label: { Image(systemName: "gearshape").frame(width: 30, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundColor(Palette.muted).help(model.text("연결 설정")).accessibilityLabel(model.text("연결 설정"))
            Button { model.isPinned.toggle(); model.onPin?(model.isPinned) } label: { Image(systemName: model.isPinned ? "pin.fill" : "pin").frame(width: 30, height: 30).foregroundColor(model.isPinned ? Palette.accent : Palette.muted).background(model.isPinned ? Palette.selected : .clear).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle()) }
                .buttonStyle(.plain).help(model.isPinned ? model.text("항상 위에 표시 중") : model.text("항상 위에 표시")).accessibilityLabel(model.text("항상 위에 표시"))
            Button { model.onCollapse?() } label: { Image(systemName: "minus").frame(width: 30, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundColor(Palette.muted).help(model.text("접기")).accessibilityLabel(model.text("접기"))
        }.padding(.horizontal, 17).padding(.top, 15).padding(.bottom, 12)
    }
    private func scopeButton(_ title: String, symbol: String, count: Int? = nil, scope: ChecklistScope) -> some View {
        Button { model.scope = scope } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol); Text(title)
                if let count { Text("\(count)").font(.system(size: 10)).monospacedDigit() }
            }
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundColor(model.scope == scope ? Palette.accent : Palette.muted)
                .background(model.scope == scope ? Palette.selected : .clear).clipShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityLabel(count.map { "\(title) \($0)" } ?? title).accessibilityAddTraits(model.scope == scope ? .isSelected : [])
    }
    /// Opens a companion app. Hidden when the app is not installed.
    /// Styled like the unselected scope tabs. The installed app's own icon is shown in grayscale to match the muted text.
    @ViewBuilder private func appButton(name: String, bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Button { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in } } label: {
                HStack(spacing: 5) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 15, height: 15).saturation(0).opacity(0.8)
                    Text(name)
                }
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 8)
                    .foregroundColor(Palette.muted).contentShape(Rectangle())
            }.buttonStyle(.plain).help(model.text("{name} 열기", ["name": name])).accessibilityLabel(model.text("{name} 열기", ["name": name]))
        }
    }
    private func categoryButton(_ name: String, category: TaskCategory? = nil) -> some View {
        let id = category?.id
        let count = model.categoryCount(id)
        return Button { model.categoryID = id } label: {
            HStack(spacing: 5) {
                if let category { CategoryDot(color: category.displayColor) }
                Text(name)
                if count > 0 { Text("\(count)").monospacedDigit() }
            }
                .font(.system(size: 10)).padding(.horizontal, 7).padding(.vertical, 5)
                .foregroundColor(model.categoryID == id ? .primary : Palette.muted)
                .background(model.categoryID == id ? Palette.soft : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel(model.text("카테고리 {name}", ["name": name])).accessibilityAddTraits(model.categoryID == id ? .isSelected : [])
        .contextMenu {
            if let category {
                Button(model.text("카테고리 색상 변경…")) { categoryToRecolor = category }
                if category.id != "uncategorized" {
                    Button(model.text("카테고리 삭제…"), role: .destructive) { categoryToDelete = category }
                }
            }
        }
    }
    private func itemRow(_ item: ChecklistItem) -> some View {
        let categoryColor = model.categoryColor(item.categoryID)
        return VStack(spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                if !model.showArchived {
                    Button { model.archive(item) } label: { Image(systemName: "square").font(.system(size: 17, weight: .light)).foregroundColor(Palette.muted).frame(width: 19, height: 23) }
                        .buttonStyle(.plain).help(model.text("목록에서 빼고 보관")).accessibilityLabel(model.text("{title} 보관", ["title": item.title]))
                }
                VStack(alignment: .leading, spacing: 7) {
                    if item.sourceURL != nil {
                        Button { model.openSource(item) } label: { HStack(alignment: .firstTextBaseline, spacing: 5) { Text(item.title).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true); Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundColor(Palette.muted) } }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).help(item.sourceURL ?? "").accessibilityLabel(model.text("{title}, {source} 원문 열기", ["title": item.title, "source": model.text(item.sourceApp.label)]))
                    } else { Text(item.title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true) }
                    FlowLayout(spacing: 6) {
                        HStack(spacing: 4) {
                            CategoryDot(color: categoryColor)
                            Menu {
                                ForEach(model.document.categories) { category in
                                    Button(category.displayName(in: model.language)) { model.changeCategory(item, to: category.id) }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(model.categoryName(item.categoryID))
                                    Image(systemName: "chevron.down").font(.system(size: 7))
                                }
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel(model.text("{title} 카테고리", ["title": item.title]))
                        }
                        .font(.system(size: 10)).padding(.horizontal, 5)
                        .background(categoryColor.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        HStack(spacing: 4) { Image(systemName: item.sourceApp.symbol); Text(model.text(item.sourceApp.label)) }.font(.system(size: 10)).foregroundColor(Palette.muted)
                        if let url = item.sourceURL.flatMap({ URL(string: $0) }), url.scheme?.hasPrefix("http") == true, let host = url.host { Text(host.replacingOccurrences(of: "www.", with: "")).font(.system(size: 10)).foregroundColor(Palette.muted) }
                        // The title returns to the conversation; this opens the related site (ticket, PR, document).
                        if let related = item.relatedURL, let url = URL(string: related), let host = url.host {
                            let name = host.replacingOccurrences(of: "www.", with: "")
                            Button { model.openRelated(item) } label: {
                                HStack(spacing: 3) { Image(systemName: "link"); Text(name).underline(); Image(systemName: "arrow.up.right").font(.system(size: 7)) }
                                    .font(.system(size: 10)).foregroundColor(Palette.accent)
                            }.buttonStyle(.plain).help(related).accessibilityLabel(model.text("{host} 열기", ["host": name]))
                        }
                    }
                    TaskContextLine(item: item, language: model.language)
                    if let date = item.archivedAt { Text(date, style: .relative).font(.system(size: 10)).foregroundColor(Palette.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.showArchived {
                    HStack(spacing: 4) {
                        Button { model.restore(item) } label: { Label(model.text("복구"), systemImage: "arrow.uturn.backward").font(.system(size: 10)) }.buttonStyle(.bordered).controlSize(.small).accessibilityLabel(model.text("{title} 복구", ["title": item.title]))
                        Button { model.delete([item]) } label: { Image(systemName: "trash").font(.system(size: 10)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundColor(Palette.muted).help(model.text("완전히 삭제")).accessibilityLabel(model.text("{title} 완전히 삭제", ["title": item.title]))
                    }
                }
            }.padding(.vertical, 17)
            .contextMenu {
                Button(model.text("작업 출처 편집…")) { model.contextItem = item }
                if !item.note.isEmpty { Button(model.text("메모 보기")) { model.noteItem = item } }
                if let link = item.sourceURL { Button(model.text("원문 링크 복사")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) } }
                if let link = item.relatedURL { Button(model.text("관련 링크 복사")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) } }
                if item.isArchived { Divider(); Button(model.text("완전히 삭제"), role: .destructive) { model.delete([item]) } }
            }
        }
    }
    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: model.showArchived ? "archivebox" : "checklist").font(.system(size: 24, weight: .light)).foregroundColor(Palette.accent)
            Text(model.categoryID != nil ? model.text("이 카테고리에는 항목이 없어요") : model.showArchived ? model.text("아직 보관한 항목이 없어요") : model.text("아직 챙길 일이 없어요")).font(.system(size: 13, weight: .medium))
            Text(model.showArchived ? model.text("체크한 항목을 여기서 다시 꺼낼 수 있어요.") : model.text("나중에 확인할 일을 여기에 모아두세요.")).font(.system(size: 11)).foregroundColor(Palette.muted)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var footer: some View {
        HStack {
            Button { model.showAdd = true } label: { Label(model.text("할 일 추가"), systemImage: "plus").font(.system(size: 11)) }.buttonStyle(.plain).disabled(model.fatalError != nil)
            Spacer()
            if model.showArchived && model.archiveCount > 0 {
                Button { confirmEmpty = true } label: { Label(model.text("보관함 비우기"), systemImage: "trash").font(.system(size: 11)) }.buttonStyle(.plain).foregroundColor(Palette.muted)
                    .confirmationDialog(model.text("보관함의 항목 {count}개를 완전히 삭제할까요?", ["count": String(model.archiveCount)]), isPresented: $confirmEmpty) {
                        Button(model.text("완전히 삭제"), role: .destructive) { model.emptyArchive() }
                        Button(model.text("취소"), role: .cancel) {}
                    } message: { Text(model.text("삭제한 직후 ‘되돌리기’로만 복구할 수 있어요.")) }
            } else if model.scope != .review {
                Text(model.showArchived ? model.text("언제든 복구할 수 있어요") : model.text("체크하면 보관함으로")).font(.system(size: 10)).foregroundColor(Palette.muted)
            }
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9)).foregroundColor(Palette.muted).help(model.text("창 모서리를 드래그해 크기를 조절하세요")).allowsHitTesting(false)
        }.padding(.horizontal, 17).padding(.vertical, 13).background(Palette.soft)
    }
}

struct AddItemView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var link = ""
    @State private var note = ""
    @State private var sessionName = ""
    @State private var projectName = ""
    @State private var source = SourceApp.manual
    @State private var category = "uncategorized"
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(model.text("챙길 일 추가")).font(.system(size: 18, weight: .medium))
            TextField(model.text("해야 할 일을 한 줄로"), text: $title).textFieldStyle(.roundedBorder).accessibilityLabel(model.text("할 일 제목"))
            TextField(model.text("원문 링크 (선택)"), text: $link).textFieldStyle(.roundedBorder).accessibilityLabel(model.text("원문 링크"))
                .onChange(of: link) { value in if value.hasPrefix("codex:") { source = .codex } else if value.hasPrefix("claude:") || URL(string: value)?.host?.contains("claude.ai") == true { source = .claude } else if value.hasPrefix("http") { source = .chrome } }
            HStack {
                Picker(model.text("출처"), selection: $source) { ForEach(SourceApp.allCases) { Text(model.text($0.label)).tag($0) } }
                Picker(model.text("카테고리"), selection: $category) { ForEach(model.document.categories) { Text($0.displayName(in: model.language)).tag($0.id) } }
            }
            HStack {
                TextField(model.text("프로젝트명 (선택)"), text: $projectName).textFieldStyle(.roundedBorder)
                TextField(model.text("세션 이름 (선택)"), text: $sessionName).textFieldStyle(.roundedBorder)
            }
            TextField(model.text("함께 남길 메모 (선택)"), text: $note).textFieldStyle(.roundedBorder)
            if let error { Text(model.text(error)).font(.system(size: 11)).foregroundColor(.red) }
            HStack { Button(model.text("취소")) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(model.text("추가")) {
                do {
                    try model.add(CaptureRequest(title: title, sourceApp: source, sourceURL: link, note: note,
                                                 categoryID: category, sessionName: sessionName, projectName: projectName))
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420)
    }
}

struct CategoryEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var color: CategoryColor
    @State private var error: String?
    let category: TaskCategory?

    init(model: AppModel, category: TaskCategory? = nil) {
        self.model = model
        self.category = category
        _color = State(initialValue: category?.displayColor ?? .gray)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let category {
                Text(category.displayName(in: model.language)).font(.headline)
            } else {
                Text(model.text("카테고리 추가")).font(.headline)
                TextField(model.text("카테고리 이름"), text: $name).textFieldStyle(.roundedBorder)
            }
            CategoryColorPicker(model: model, selection: $color)
            if let error { Text(model.text(error)).font(.system(size: 11)).foregroundColor(.red) }
            HStack {
                Button(model.text("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.text(category == nil ? "추가" : "저장")) {
                    do {
                        if let category { try model.changeCategoryColor(category, to: color) }
                        else { try model.addCategory(name, color: color) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 320)
    }
}
