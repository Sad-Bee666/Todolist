import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: SettingsStore

    @State private var keyDraft: String = ""
    @State private var testResult: String?
    @State private var testing = false

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { settings.settings.ai.provider },
            set: { settings.applyProviderDefaults($0); reloadKey() }
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
        .frame(width: 520, height: 620)
        .onAppear { reloadKey() }
        .onChange(of: settings.settings.ai.provider) { _ in reloadKey() }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 接口").font(.headline)
            Picker("预设", selection: providerBinding) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            labeledField("Base URL", text: $settings.settings.ai.baseURL, placeholder: "https://api.deepseek.com/v1")
            labeledField("模型", text: $settings.settings.ai.model, placeholder: "deepseek-chat")
            Text("协议为 OpenAI 兼容（POST <Base URL>/chat/completions）。DeepSeek 与 OpenAI 已内置预设；其它厂商选「自定义」后自行填写 Base URL 与模型名。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key").font(.headline)
            HStack(spacing: 6) {
                SecureField("sk-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("保存") { saveKey() }
                Button("删除") { deleteKey() }
            }
            HStack(spacing: 8) {
                Button(testing ? "测试中…" : "测试连接") { runTest() }
                    .disabled(testing || keyDraft.isEmpty)
                Text(app.keyPresent ? "已保存（优先钥匙串）" : "未配置：当前用本地规则解析")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
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
            Text("手写填入与截图识别都会自动解析出截止时间后写入，无需额外点击。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("预留接口：QQ / 微信通道已在代码中定义（IMBridge / IMBridgeRegistry），本版本不包含收发功能。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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

    private func saveKey() {
        SecretBox.save(keyDraft, account: SecretBox.account(for: settings.settings.ai.provider))
        app.refreshKeyPresence()
        testResult = keyDraft.isEmpty ? "已清空 Key" : "已保存"
    }

    private func deleteKey() {
        SecretBox.delete(account: SecretBox.account(for: settings.settings.ai.provider))
        keyDraft = ""
        app.refreshKeyPresence()
        testResult = "已删除 Key"
    }

    private func runTest() {
        SecretBox.save(keyDraft, account: SecretBox.account(for: settings.settings.ai.provider))
        app.refreshKeyPresence()
        testing = true
        testResult = nil
        Task { @MainActor in
            let result = await app.testAIConnection()
            testResult = result
            testing = false
        }
    }
}
