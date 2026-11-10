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
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ChecklistView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if model.isCollapsed { compact }
            else { full }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .tint(Palette.accent)
        .environment(\.locale, model.language.locale)
        .sheet(isPresented: $model.showAdd) { AddItemView(model: model) }
        .sheet(isPresented: $model.showCategoryEditor) { AddCategoryView(model: model) }
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
            HStack(spacing: 6) {
                scopeButton(model.text("할 일"), symbol: "checklist", count: model.activeCount, archived: false)
                scopeButton(model.text("보관함"), symbol: "archivebox", count: model.archiveCount, archived: true)
                Spacer()
            }.padding(.horizontal, 17).padding(.bottom, 12)
            FlowLayout {
                categoryButton(model.text("전체"), id: nil)
                ForEach(model.document.categories) { category in categoryButton(category.displayName(in: model.language), id: category.id) }
                Button { model.showCategoryEditor = true } label: { Image(systemName: "plus").font(.system(size: 10)).padding(6) }
                    .buttonStyle(.plain).foregroundColor(Palette.muted).help(model.text("카테고리 추가")).accessibilityLabel(model.text("카테고리 추가"))
            }.padding(.horizontal, 17).padding(.bottom, 13)
            if let error = model.fatalError {
                ScrollView { VStack(spacing: 16) { Image(systemName: "exclamationmark.triangle"); Text(model.text(error)).font(.system(size: 12)); Button(model.text("데이터 폴더 열기")) { NSWorkspace.shared.open(model.dataDirectory) } }.padding(20) }
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
                    if model.undoItem != nil { Button(model.text("되돌리기")) { model.undo() }.buttonStyle(.plain).font(.system(size: 11)).underline() }
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
    private func scopeButton(_ title: String, symbol: String, count: Int, archived: Bool) -> some View {
        Button { model.showArchived = archived } label: {
            HStack(spacing: 6) { Image(systemName: symbol); Text(title); Text("\(count)").font(.system(size: 10)).monospacedDigit() }
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundColor(model.showArchived == archived ? Palette.accent : Palette.muted)
                .background(model.showArchived == archived ? Palette.selected : .clear).clipShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityLabel("\(title) \(count)").accessibilityAddTraits(model.showArchived == archived ? .isSelected : [])
    }
    private func categoryButton(_ name: String, id: String?) -> some View {
        let count = model.categoryCount(id)
        return Button { model.categoryID = id } label: {
            HStack(spacing: 5) { Text(name); if count > 0 { Text("\(count)").monospacedDigit() } }
                .font(.system(size: 10)).padding(.horizontal, 7).padding(.vertical, 5)
                .foregroundColor(model.categoryID == id ? .primary : Palette.muted)
                .background(model.categoryID == id ? Palette.soft : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel(model.text("카테고리 {name}", ["name": name])).accessibilityAddTraits(model.categoryID == id ? .isSelected : [])
    }
    private func itemRow(_ item: ChecklistItem) -> some View {
        VStack(spacing: 0) {
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
                        Menu {
                            ForEach(model.document.categories) { category in Button(category.displayName(in: model.language)) { model.changeCategory(item, to: category.id) } }
                        } label: { HStack(spacing: 3) { Text(model.categoryName(item.categoryID)); Image(systemName: "chevron.down").font(.system(size: 7)) }.font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 3).background(Palette.soft).clipShape(RoundedRectangle(cornerRadius: 5)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(model.text("{title} 카테고리", ["title": item.title]))
                        HStack(spacing: 4) { Image(systemName: item.sourceApp.symbol); Text(model.text(item.sourceApp.label)) }.font(.system(size: 10)).foregroundColor(Palette.muted)
                        if let host = item.sourceURL.flatMap({ URL(string: $0)?.host }), host != "threads" { Text(host.replacingOccurrences(of: "www.", with: "")).font(.system(size: 10)).foregroundColor(Palette.muted) }
                    }
                    if let date = item.archivedAt { Text(date, style: .relative).font(.system(size: 10)).foregroundColor(Palette.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.showArchived {
                    Button { model.restore(item) } label: { Label(model.text("복구"), systemImage: "arrow.uturn.backward").font(.system(size: 10)) }.buttonStyle(.bordered).controlSize(.small).accessibilityLabel(model.text("{title} 복구", ["title": item.title]))
                }
            }.padding(.vertical, 17)
            .contextMenu {
                if !item.note.isEmpty { Button(model.text("메모 보기")) { model.noteItem = item } }
                if let link = item.sourceURL { Button(model.text("원문 링크 복사")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) } }
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
            Text(model.showArchived ? model.text("언제든 복구할 수 있어요") : model.text("체크하면 보관함으로")).font(.system(size: 10)).foregroundColor(Palette.muted)
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
    @State private var source = SourceApp.manual
    @State private var category = "uncategorized"
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(model.text("챙길 일 추가")).font(.system(size: 18, weight: .medium))
            TextField(model.text("해야 할 일을 한 줄로"), text: $title).textFieldStyle(.roundedBorder).accessibilityLabel(model.text("할 일 제목"))
            TextField(model.text("원문 링크 (선택)"), text: $link).textFieldStyle(.roundedBorder).accessibilityLabel(model.text("원문 링크"))
                .onChange(of: link) { value in if value.hasPrefix("codex:") { source = .codex } else if URL(string: value)?.host?.contains("claude.ai") == true { source = .claude } else if value.hasPrefix("http") { source = .chrome } }
            HStack {
                Picker(model.text("출처"), selection: $source) { ForEach(SourceApp.allCases) { Text(model.text($0.label)).tag($0) } }
                Picker(model.text("카테고리"), selection: $category) { ForEach(model.document.categories) { Text($0.displayName(in: model.language)).tag($0.id) } }
            }
            TextField(model.text("함께 남길 메모 (선택)"), text: $note).textFieldStyle(.roundedBorder)
            if let error { Text(model.text(error)).font(.system(size: 11)).foregroundColor(.red) }
            HStack { Button(model.text("취소")) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(model.text("추가")) {
                do { try model.add(CaptureRequest(title: title, sourceApp: source, sourceURL: link, note: note, categoryID: category)); dismiss() } catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420)
    }
}

struct AddCategoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(model.text("카테고리 추가")).font(.headline)
            TextField(model.text("카테고리 이름"), text: $name).textFieldStyle(.roundedBorder)
            if let error { Text(model.text(error)).font(.system(size: 11)).foregroundColor(.red) }
            HStack { Button(model.text("취소")) { dismiss() }; Spacer(); Button(model.text("추가")) { do { try model.addCategory(name); dismiss() } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 320)
    }
}
