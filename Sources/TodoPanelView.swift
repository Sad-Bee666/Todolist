import SwiftUI
import AppKit

struct PanelActions {
    var addManual: (String) -> Void
    var toggleDone: (UUID) -> Void
    var deleteItem: (UUID) -> Void
    var startCapture: () -> Void
    var openSettings: () -> Void
    var clearCompleted: () -> Void
    var quit: () -> Void
}

enum DeadlineText {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: date)

        if calendar.isDateInToday(date) { return "今天 " + time }
        if calendar.isDateInTomorrow(date) { return "明天 " + time }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func todayAt(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static func tomorrowAt(_ hour: Int, _ minute: Int) -> Date {
        let base = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
    }
}

struct TodoPanelView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var app: AppController
    let actions: PanelActions

    @State private var draftTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            bodyContent
            Divider()
            footer
        }
        .frame(width: 380, height: 520)
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .todoPanelClearDraft)) { _ in
            draftTitle = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoPanelFillDraft)) { note in
            if let text = note.userInfo?["text"] as? String { draftTitle = text }
        }
    }

    private var subtitle: String {
        if store.items.isEmpty { return "还没有待办" }
        let pending = store.pendingCount()
        let overdue = store.overdueCount()
        if pending == 0 { return "全部完成" }
        return overdue > 0 ? "\(pending) 项待办 · \(overdue) 项已过期" : "\(pending) 项待办"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 13, weight: .semibold))
            Text("待办").font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundColor(store.overdueCount() > 0 ? .red : .secondary)
            Spacer()
            Button { actions.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundColor(.secondary).help("设置")
            Menu {
                Button("清除已完成") { actions.clearCompleted() }
                Button("打开数据文件夹") {
                    NSWorkspace.shared.activateFileViewerSelecting([TodoStore.defaultDirectory()])
                }
                Divider()
                Button("退出 Todolist") { actions.quit() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 18)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var bodyContent: some View {
        Group {
            if store.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 22)).foregroundColor(.secondary)
                    Text("还没有待办").font(.system(size: 12)).foregroundColor(.secondary)
                    Text("在下方手写填入，或用 ⌃⌥T 截图识别").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(store.sortedItems()) { item in
                            row(item)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { actions.toggleDone(item.id) } label: {
                Image(systemName: item.isDone ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(item.isDone ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12))
                    .strikethrough(item.isDone)
                    .foregroundColor(item.isDone ? .secondary : (item.isOverdue ? .red : .primary))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let deadline = item.deadline {
                        HStack(spacing: 3) {
                            Image(systemName: "clock").font(.system(size: 9))
                            Text(DeadlineText.short(deadline)).font(.system(size: 10))
                        }
                        .foregroundColor(item.isOverdue ? .red : .secondary)
                    } else {
                        Text("无截止时间").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
                    }
                    Text(item.source.label)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(3)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 2)
            Button { actions.deleteItem(item.id) } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .opacity(0.75)
            .help("删除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if app.isBusy {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    Text("处理中…").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if let message = app.statusMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(app.statusIsError ? .red : .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                TextField("手写填入，如：交房租 明天 18:00", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commit() }
                Button("添加") { commit() }
                    .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 8) {
                Button { actions.startCapture() } label: {
                    Label("截图识别", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.bordered)
                modelMenu
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(
                    get: { app.settings.settings.useRemoteModel },
                    set: { app.setUseRemoteModel($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("用配置的 API 模型解析待办；关闭则用本地规则解析")
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var modelMenu: some View {
        Menu {
            let selectable = app.settings.settings.ai.selectableModels
            if selectable.isEmpty {
                Text("还没配置模型")
            } else {
                ForEach(selectable, id: \.self) { model in
                    Button(model == app.settings.settings.ai.model ? "✓ " + model : model) {
                        app.useModel(model)
                    }
                }
            }
            Divider()
            Button("更多设置…") { actions.openSettings() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(app.usesRemoteModel ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Image(systemName: app.usesRemoteModel ? "sparkles" : "cpu")
                    .font(.system(size: 10))
                Text(app.modelLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundColor(app.settings.settings.useRemoteModel ? .primary : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(app.usesRemoteModel
              ? "当前使用 \(app.settings.settings.ai.model) 解析，点击切换模型"
              : "当前用本地规则解析，点击选择模型")
    }

    private func commit() {
        let text = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.addManual(text)
    }
}
