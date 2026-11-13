import SwiftUI
import CheckerCore

extension CategoryColor {
    var tint: Color {
        switch self {
        case .gray: return Palette.muted
        case .red: return Palette.color(0xB53B43, 0xF18A8F)
        case .orange: return Palette.color(0xA55625, 0xF2A368)
        case .yellow: return Palette.color(0x846500, 0xE6C366)
        case .green: return Palette.color(0x46724B, 0x9DCA93)
        case .teal: return Palette.color(0x2B736F, 0x78C8BC)
        case .blue: return Palette.color(0x33699D, 0x8EBFF1)
        case .purple: return Palette.color(0x7952A3, 0xC4A3EF)
        }
    }

    var label: String {
        switch self {
        case .gray: return "회색"
        case .red: return "빨강"
        case .orange: return "주황"
        case .yellow: return "노랑"
        case .green: return "초록"
        case .teal: return "청록"
        case .blue: return "파랑"
        case .purple: return "보라"
        }
    }
}

struct CategoryDot: View {
    let color: CategoryColor

    var body: some View {
        Circle().fill(color.tint).frame(width: 6, height: 6).accessibilityHidden(true)
    }
}

struct CategoryColorPicker: View {
    @ObservedObject var model: AppModel
    @Binding var selection: CategoryColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text("카테고리 색상")).font(.system(size: 11)).foregroundColor(Palette.muted)
            HStack(spacing: 6) {
                ForEach(CategoryColor.allCases) { color in
                    Button { selection = color } label: {
                        Circle().fill(color.tint).frame(width: 17, height: 17)
                            .overlay {
                                if selection == color {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                        .foregroundColor(Palette.background)
                                }
                            }
                            .frame(width: 25, height: 25)
                            .background(selection == color ? Palette.soft : .clear, in: Circle())
                            .overlay(Circle().strokeBorder(selection == color ? color.tint : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.text(color.label))
                    .accessibilityAddTraits(selection == color ? .isSelected : [])
                    .help(model.text(color.label))
                }
            }
        }
    }
}

struct TaskContextLine: View {
    let item: ChecklistItem
    let language: AppLanguage

    var body: some View {
        if item.projectName != nil || item.sessionName != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let project = item.projectName {
                    context(project, label: "프로젝트명", symbol: "folder")
                }
                if let session = item.sessionName {
                    context(session, label: "세션 이름", symbol: "bubble.left")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(Palette.muted)
        }
    }

    private func context(_ name: String, label: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).frame(width: 12)
            Text(name).lineLimit(1).truncationMode(.tail)
        }
        .help(language.text(label) + " · " + name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text(label))
        .accessibilityValue(name)
    }
}

struct TaskContextEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let item: ChecklistItem
    @State private var sessionName: String
    @State private var projectName: String
    @State private var error: String?

    init(model: AppModel, item: ChecklistItem) {
        self.model = model
        self.item = item
        _sessionName = State(initialValue: item.sessionName ?? "")
        _projectName = State(initialValue: item.projectName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.text("작업 출처 편집")).font(.headline)
            Text(item.title).font(.system(size: 12)).foregroundColor(Palette.muted).lineLimit(2)
            TextField(model.text("프로젝트명 (선택)"), text: $projectName).textFieldStyle(.roundedBorder)
            TextField(model.text("세션 이름 (선택)"), text: $sessionName).textFieldStyle(.roundedBorder)
            if let error { Text(model.text(error)).font(.system(size: 11)).foregroundColor(.red) }
            HStack {
                Button(model.text("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.text("저장")) {
                    do {
                        try model.changeContext(item, sessionName: sessionName, projectName: projectName)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 350)
    }
}
