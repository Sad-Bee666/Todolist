import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: SettingsStore

    @State private var keyDraft: String = ""
    @State private var showKey: Bool = false
    @State private var testing: Bool = false
    @State private var fetching: Bool = false
    @State private var probeMessage: String?
    @State private var availableModels: [String] = []
    @State private var showModelChooser: Bool = false
    @State private var selectedModels: Set<String> = []

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { settings.settings.ai.provider },
            set: { newValue in
                settings.applyProviderDefaults(newValue)
                availableModels = []
                reloadKey()
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.settings.ai.model },
            set: { settings.settings.ai.model = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                aiSection
                Divider()
                keySection
                Divider()
                hotkeySection
                Divider()
                behaviorSection
            }
            .padding(18)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            reloadKey()
            autoFillFromPasteboard()
            if app.keyPresent { refreshModels(showError: false) }
        }
        .onChange(of: settings.settings.ai.provider) { _ in
            availableModels = []
            reloadKey()
        }
        .sheet(isPresented: $showModelChooser) {
            ModelChooser(
                models: availableModels.isEmpty ? settings.settings.ai.selectableModels : availableModels,
                selected: $selectedModels,
                onCommit: { picked in
                    applySelectedModels(picked)
                    showModelChooser = false
                },
                onCancel: { showModelChooser = false }
            )
        }
    }

    // MARK: - 接口

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 接口").font(.headline)

            labeledField("Base URL", text: $settings.settings.ai.baseURL, placeholder: "https://api.deepseek.com/v1")

            HStack(spacing: 8) {
                Text("模型提供商").font(.system(size: 12)).frame(width: 68, alignment: .leading)
                Picker("", selection: providerBinding) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("调用模型").font(.system(size: 12)).frame(width: 68, alignment: .leading)
                Picker("", selection: modelBinding) {
                    ForEach(settings.settings.ai.selectableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
                Button("管理模型（多选）") { openModelManager() }
                    .disabled(fetching)
                Spacer()
            }

            Text("协议为 OpenAI 兼容（POST <Base URL>/chat/completions）。保存 Key 时会自动测试连通性，并列出该接口返回的模型供你选择。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key").font(.headline)
            HStack(spacing: 6) {
                Group {
                    if showKey {
                        TextField("sk-…", text: $keyDraft)
                    } else {
                        SecureField("sk-…", text: $keyDraft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

                Button(showKey ? "隐藏" : "显示") { showKey.toggle() }
                    .help("显示后可选中复制")
                Button("粘贴") { pasteKey() }
                    .help("从剪贴板填入 Key")
                Button(testing ? "测试中…" : "保存并测试") { saveAndTest() }
                    .disabled(testing)
                Button("删除") { deleteKey() }
            }
            HStack(spacing: 8) {
                Text(app.keyPresent ? "已保存（本地文件，权限 0600）" : "未配置：当前用本地规则解析")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            if let probeMessage {
                Text(probeMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 快捷键 / 行为

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("截图快捷键").font(.headline)
            HStack(spacing: 10) {
                Text(settings.settings.hotkey.display)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.14))
                    .cornerRadius(4)
                Button("重置为 ⌃⌥T") {
                    settings.settings.hotkey = .standard
                    app.registerHotKey()
                }
                Spacer()
            }
            Text("按下快捷键后框选屏幕区域，本机 Vision 完成取字。首次截图 macOS 会要求「屏幕录制」权限，请到 系统设置 → 隐私与安全性 → 屏幕录制 里勾选 Todolist 并重开本应用。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("行为").font(.headline)
            Toggle("鼠标移到菜单栏图标上自动展开面板", isOn: $settings.settings.hoverOpensPanel)
                .toggleStyle(.switch)
            Toggle("面板上的「用 API 模型」开关（关闭则用本地规则解析）", isOn: Binding(
                get: { settings.settings.useRemoteModel },
                set: { app.setUseRemoteModel($0) }
            ))
            .toggleStyle(.switch)
            Text("手写填入与截图识别都会自动解析出截止时间后写入，无需额外点击。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("预留接口：QQ / 微信通道已在代码中定义（IMBridge / IMBridgeRegistry），本版本不包含收发功能。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 动作

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).frame(width: 68, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func reloadKey() {
        keyDraft = SecretBox.load(account: SecretBox.account(for: settings.settings.ai.provider)) ?? ""
        app.refreshKeyPresence()
    }

    /// 打开设置时若还没存 Key，且剪贴板里像 Key，就自动填进输入框（不自动保存，等确认）。
    private func autoFillFromPasteboard() {
        guard keyDraft.isEmpty else { return }
        guard let candidate = app.keyFromPasteboard() else { return }
        keyDraft = candidate
        probeMessage = "已从剪贴板填入 Key，确认后点「保存并测试」"
    }

    private func pasteKey() {
        if let candidate = app.keyFromPasteboard() {
            keyDraft = candidate
            probeMessage = "已从剪贴板粘贴，点「保存并测试」"
            return
        }
        if let raw = NSPasteboard.general.string(forType: .string),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keyDraft = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            probeMessage = "剪贴板内容格式不像 Key，已原样填入，请自行核对"
        } else {
            probeMessage = "剪贴板里没有文本"
        }
    }

    private func deleteKey() {
        SecretBox.delete(account: SecretBox.account(for: settings.settings.ai.provider))
        keyDraft = ""
        availableModels = []
        app.refreshKeyPresence()
        probeMessage = "已删除 Key"
    }

    private func saveAndTest() {
        SecretBox.save(keyDraft, account: SecretBox.account(for: settings.settings.ai.provider))
        app.refreshKeyPresence()
        guard !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            probeMessage = "已清空 Key"
            return
        }
        testing = true
        probeMessage = "正在测试连通性…"
        Task { @MainActor in
            let result = await app.probeConnection()
            testing = false
            probeMessage = result.message
            availableModels = result.models
            if !result.models.isEmpty {
                selectedModels = Set(settings.settings.ai.selectableModels.filter { result.models.contains($0) })
                if selectedModels.isEmpty, let first = result.models.first { selectedModels = [first] }
                showModelChooser = true
            }
        }
    }

    private func openModelManager() {
        selectedModels = Set(settings.settings.ai.selectableModels)
        if !availableModels.isEmpty {
            showModelChooser = true
            return
        }
        guard app.keyPresent else {
            probeMessage = "先保存 API Key，才能拉取可选模型"
            return
        }
        fetching = true
        Task { @MainActor in
            let result = await app.probeConnection()
            fetching = false
            probeMessage = result.message
            availableModels = result.models
            if !result.models.isEmpty {
                selectedModels = Set(settings.settings.ai.selectableModels.filter { result.models.contains($0) })
                if selectedModels.isEmpty, let first = result.models.first { selectedModels = [first] }
                showModelChooser = true
            }
        }
    }

    private func applySelectedModels(_ picked: Set<String>) {
        guard !picked.isEmpty else { return }
        var ai = settings.settings.ai
        let ordered = (availableModels.isEmpty ? ai.selectableModels : availableModels).filter { picked.contains($0) }
        guard !ordered.isEmpty else { return }
        ai.models = ordered
        if !ordered.contains(ai.model) { ai.model = ordered[0] }
        settings.settings.ai = ai
        probeMessage = "已保留 " + String(ordered.count) + " 个模型，当前调用 " + ai.model
    }

    private func refreshModels(showError: Bool) {
        guard app.keyPresent else { return }
        fetching = true
        Task { @MainActor in
            let result = await app.probeConnection()
            fetching = false
            if !result.models.isEmpty {
                availableModels = result.models
                probeMessage = result.message
                if !result.models.contains(settings.settings.ai.model) && showError {
                    showModelChooser = true
                }
            } else if showError {
                probeMessage = result.message
            }
        }
    }
}

struct ModelChooser: View {
    let models: [String]
    @Binding var selected: Set<String>
    let onCommit: (Set<String>) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择可用模型").font(.headline)
            Text("可多选：勾选的模型会保留在列表里，之后在面板上挑一个实际调用。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(models, id: \.self) { model in
                        Toggle(isOn: Binding(
                            get: { selected.contains(model) },
                            set: { on in
                                if on { selected.insert(model) } else { selected.remove(model) }
                            }
                        )) {
                            Text(model).font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 5)
                    }
                }
            }
            .frame(height: 190)
            HStack(spacing: 8) {
                Button("全选") { selected = Set(models) }
                Button("清空") { selected = [] }
                Spacer()
                Button("取消", action: onCancel)
                Button("完成") { onCommit(selected) }
                    .disabled(selected.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}
