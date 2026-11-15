import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab(app: app, settings: settings)
                .tabItem { Label("通用", systemImage: "gearshape") }
            APIProfilesTab(app: app, settings: settings)
                .tabItem { Label("API 管理", systemImage: "network") }
        }
        .frame(width: 580, height: 640)
    }
}

// MARK: - 通用

struct GeneralSettingsTab: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: SettingsStore

    @State private var screenGranted: Bool = ScreenCapturePermission.isGranted
    @State private var captureDiagnostic: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hotkeySection
                Divider()
                captureSection
                Divider()
                behaviorSection
            }
            .padding(18)
        }
        .onAppear { screenGranted = ScreenCapturePermission.isGranted }
    }

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
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("截图权限").font(.headline)
            HStack(spacing: 8) {
                Text("屏幕录制权限").font(.system(size: 12))
                Text(screenGranted ? "已授权" : "未授权")
                    .font(.system(size: 11))
                    .foregroundColor(screenGranted ? .green : .red)
                Button("请求权限") { screenGranted = ScreenCapturePermission.request() }
                Button("重新检测") { screenGranted = ScreenCapturePermission.isGranted }
                Button("测试截图") {
                    captureDiagnostic = "正在抓一张整屏…"
                    Task { @MainActor in captureDiagnostic = await app.diagnoseCapture() }
                }
                Button("系统设置") { ScreenCapturePermission.openSystemSettings() }
                Spacer()
            }
            if let captureDiagnostic {
                Text(captureDiagnostic)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("导入桌面最近截图") { app.importLatestScreenshot() }
                    .help("按 ⇧⌘4 用系统截图，再点这里导入；这条路不需要屏幕录制权限")
                Spacer()
            }
            Text("⌃⌥T 走系统 screencapture，需要屏幕录制授权：先点「请求权限」，或到 系统设置 → 隐私与安全性 → 屏幕录制 勾选 Todolist 后**退出并重开应用**（授权要重启才生效）。")
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
}

// MARK: - API 管理

struct APIProfilesTab: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: SettingsStore

    @State private var selectedID: UUID?
    @State private var keyDraft: String = ""
    @State private var showKey: Bool = false
    @State private var testing: Bool = false
    @State private var probeMessage: String?
    @State private var availableModels: [String] = []
    @State private var showModelChooser: Bool = false
    @State private var selectedModels: Set<String> = []

    private var currentID: UUID? {
        selectedID ?? settings.settings.activeProfileID ?? settings.settings.profiles.first?.id
    }

    private var index: Int? {
        guard let currentID else { return nil }
        return settings.settings.profiles.firstIndex { $0.id == currentID }
    }

    private var profile: APIProfile? {
        guard let index else { return nil }
        return settings.settings.profiles[index]
    }

    private var isActiveProfile: Bool {
        currentID != nil && currentID == settings.settings.activeProfileID
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            profileList.frame(width: 178)
            Divider()
            ScrollView {
                editor.padding(14)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .onAppear {
            selectedID = settings.settings.activeProfileID
            loadKey()
        }
        .onChange(of: currentID) { _ in
            loadKey()
            availableModels = []
            probeMessage = nil
        }
        .sheet(isPresented: $showModelChooser) {
            ModelChooser(
                models: availableModels.isEmpty ? (profile?.selectableModels ?? []) : availableModels,
                selected: $selectedModels,
                onCommit: { picked in
                    applySelectedModels(picked)
                    showModelChooser = false
                },
                onCancel: { showModelChooser = false }
            )
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(settings.settings.profiles) { item in
                        Button { selectedID = item.id } label: {
                            HStack(spacing: 4) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(.system(size: 12, weight: item.id == currentID ? .semibold : .regular))
                                        .lineLimit(1)
                                    Text(item.model)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 2)
                                if settings.settings.activeProfileID == item.id {
                                    Text("当前")
                                        .font(.system(size: 9))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.16))
                                        .cornerRadius(3)
                                }
                            }
                            .padding(6)
                            .background(item.id == currentID ? Color.secondary.opacity(0.12) : Color.clear)
                            .cornerRadius(5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 6) {
                Button("新建") {
                    let newID = app.addProfile()
                    selectedID = newID
                }
                Button("删除") {
                    guard let currentID else { return }
                    app.deleteProfile(currentID)
                    selectedID = settings.settings.activeProfileID
                }
                .disabled(settings.settings.profiles.count <= 1)
                Spacer()
            }
            .font(.system(size: 11))
            .padding(6)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let profile, let currentID {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(profile.name.isEmpty ? "未命名" : profile.name).font(.headline)
                    if isActiveProfile {
                        Text("使用中").font(.system(size: 10))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.16)).cornerRadius(3)
                    } else {
                        Button("设为当前") { app.setActiveProfile(currentID) }
                            .font(.system(size: 11))
                    }
                    Spacer()
                }

                field("名称") {
                    TextField("例如：DeepSeek 主号", text: stringBinding(\.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                field("提供商") {
                    Picker("", selection: providerBinding) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }

                field("Base URL") {
                    TextField("https://api.deepseek.com/v1", text: stringBinding(\.baseURL))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                field("调用模型") {
                    Picker("", selection: stringBinding(\.model)) {
                        ForEach(profile.selectableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    Button("管理模型（多选）") { openModelManager() }
                        .disabled(testing)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key").font(.system(size: 12, weight: .medium))
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
                        Button("粘贴") { pasteKey() }
                        Button(testing ? "测试中…" : "保存并测试") { saveAndTest(profileID: currentID) }
                            .disabled(testing)
                        Button("删除 Key") { app.deleteKey(for: currentID); keyDraft = ""; probeMessage = "已删除 Key" }
                    }
                    Text(app.key(for: currentID).isEmpty ? "未保存 Key" : "已保存（0600 本地文件）")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if let probeMessage {
                        Text(probeMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button("测试连接") { probe(profileID: currentID) }
                        .disabled(testing)
                    Spacer()
                }
                .font(.system(size: 11))

                Text("协议为 OpenAI 兼容（POST <Base URL>/chat/completions）。保存 Key 时自动请求 /models 验证连通性并列出模型；面板上列出的就是这份配置多选的模型。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("左侧新建一份 API 配置").foregroundColor(.secondary).padding(.top, 20)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).frame(width: 66, alignment: .leading)
            content()
            Spacer()
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<APIProfile, String>) -> Binding<String> {
        Binding(
            get: { profile?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index else { return }
                settings.settings.profiles[index][keyPath: keyPath] = newValue
            }
        )
    }

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { profile?.provider ?? .deepseek },
            set: { newValue in
                guard let index else { return }
                settings.settings.profiles[index].provider = newValue
                settings.settings.profiles[index].baseURL = newValue.defaultBaseURL
                let defaultModel = newValue.defaultModel
                if !defaultModel.isEmpty {
                    settings.settings.profiles[index].model = defaultModel
                    if !settings.settings.profiles[index].models.contains(defaultModel) {
                        settings.settings.profiles[index].models.insert(defaultModel, at: 0)
                    }
                }
                availableModels = []
                app.refreshKeyPresence()
            }
        )
    }

    private func loadKey() {
        guard let currentID else { keyDraft = ""; return }
        keyDraft = app.key(for: currentID)
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

    private func saveAndTest(profileID: UUID) {
        app.saveKey(keyDraft, for: profileID)
        guard !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            probeMessage = "已清空 Key"
            availableModels = []
            return
        }
        probe(profileID: profileID)
    }

    private func probe(profileID: UUID) {
        testing = true
        probeMessage = "正在测试连通性…"
        Task { @MainActor in
            let result = await app.probeConnection(profileID: profileID)
            testing = false
            probeMessage = result.message
            availableModels = result.models
            if !result.models.isEmpty {
                let current = profile?.selectableModels ?? []
                selectedModels = Set(current.filter { result.models.contains($0) })
                if selectedModels.isEmpty, let first = result.models.first { selectedModels = [first] }
                showModelChooser = true
            }
        }
    }

    private func openModelManager() {
        guard let profile else { return }
        selectedModels = Set(profile.selectableModels)
        if !availableModels.isEmpty {
            showModelChooser = true
            return
        }
        guard !app.key(for: profile.id).isEmpty else {
            probeMessage = "先保存 API Key，才能拉取可选模型"
            return
        }
        probe(profileID: profile.id)
    }

    private func applySelectedModels(_ picked: Set<String>) {
        guard let index, !picked.isEmpty else { return }
        let source = availableModels.isEmpty ? settings.settings.profiles[index].selectableModels : availableModels
        let ordered = source.filter { picked.contains($0) }
        guard !ordered.isEmpty else { return }
        settings.settings.profiles[index].models = ordered
        if !ordered.contains(settings.settings.profiles[index].model) {
            settings.settings.profiles[index].model = ordered[0]
        }
        probeMessage = "已保留 " + String(ordered.count) + " 个模型，当前调用 " + settings.settings.profiles[index].model
    }
}

// MARK: - 模型多选

struct ModelChooser: View {
    let models: [String]
    @Binding var selected: Set<String>
    let onCommit: (Set<String>) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择可用模型").font(.headline)
            Text("可多选：勾选的模型会保留在这份 API 配置里，之后在面板上挑一个实际调用。")
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
