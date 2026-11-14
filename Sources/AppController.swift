import AppKit
import SwiftUI
import Combine

final class AppController: ObservableObject, TodoIngest {
    static let shared = AppController()

    @Published var statusMessage: String?
    @Published var statusIsError: Bool = false
    @Published var isBusy: Bool = false
    @Published var keyPresent: Bool = false

    let store = TodoStore.shared
    let settings = SettingsStore.shared

    private let remoteAI = OpenAICompatibleAIClient()
    private let localAI = MockAIService()
    private let ocr: OCRServicing = ScreenOCRService()
    private let hotKey = HotKeyManager()
    private var statusController: StatusItemController?
    private var settingsWindow: NSWindow?

    var onHidePanel: (() -> Void)?

    private init() {
        IMBridgeRegistry.shared.register(QQBridge())
        IMBridgeRegistry.shared.register(WeChatBridge())
    }

    func start() {
        refreshKeyPresence()

        let panel = TodoPanelView(store: store, app: self, actions: makeActions())
        let hosting = NSHostingController(rootView: panel)
        statusController = StatusItemController(
            contentViewController: hosting,
            hoverEnabled: { [weak self] in self?.settings.settings.hoverOpensPanel ?? true },
            closeDelay: { [weak self] in self?.settings.settings.hoverCloseDelay ?? 0.35 }
        )
        statusController?.onWillOpen = { [weak self] in self?.refreshKeyPresence() }
        onHidePanel = { [weak self] in self?.statusController?.closePanel() }
        statusController?.install()

        hotKey.handler = { [weak self] in self?.beginCaptureFromHotKey() }
        let registered = hotKey.register(settings.settings.hotkey)
        NSLog("[app] hotkey registered=%@ spec=%@", registered ? "true" : "false", settings.settings.hotkey.display)
        if !registered {
            postStatus("全局快捷键注册失败，可在设置里换一个组合键", isError: true)
        }
    }

    /// 真正生效的远端判定：开关打开 + 有 Key + 接口可路由。
    var usesRemoteModel: Bool {
        settings.settings.useRemoteModel && keyPresent && settings.settings.ai.isRoutable
    }

    var modelLabel: String {
        guard settings.settings.useRemoteModel else { return "本地规则" }
        let model = settings.settings.ai.model
        guard !model.isEmpty else { return "选择模型" }
        return keyPresent ? model : model + " · 缺 Key"
    }

    func setUseRemoteModel(_ enabled: Bool) {
        settings.settings.useRemoteModel = enabled
        if enabled && !keyPresent {
            postStatus("还没有 API Key：齿轮 → 填 Key。当前仍走本地规则", isError: true)
        } else if enabled {
            postStatus("已启用 API 模型：\(settings.settings.ai.model)")
        } else {
            postStatus("已切回本地规则")
        }
    }

    func selectModel(_ provider: AIProvider, _ model: String) {
        settings.applyProviderDefaults(provider)
        settings.settings.ai.model = model
        if !settings.settings.useRemoteModel {
            settings.settings.useRemoteModel = true
        }
        refreshKeyPresence()
        if keyPresent {
            postStatus("已切换到 \(provider.displayName) · \(model)")
        } else {
            postStatus("已选 \(provider.displayName) · \(model)，还缺 \(provider.displayName) 的 API Key", isError: true)
        }
    }

    func makeActions() -> PanelActions {
        PanelActions(
            addManual: { [weak self] text in self?.addManual(text: text) },
            toggleDone: { [weak self] id in self?.store.toggleDone(id: id) },
            deleteItem: { [weak self] id in self?.store.remove(id: id) },
            startCapture: { [weak self] in self?.beginCapture() },
            openSettings: { [weak self] in self?.openSettings() },
            clearCompleted: { [weak self] in self?.store.clearCompleted() },
            quit: { NSApp.terminate(nil) }
        )
    }

    // MARK: - 手写填入

    /// 手写填入：与截图走同一条抽取管线（有 Key 用模型，没有则本地规则）。
    func addManual(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { self.isBusy = false }
            do {
                let added = try await self.extractAndStoreReturningCount(text: text, source: .manual)
                if added > 0 {
                    NotificationCenter.default.post(name: .todoPanelClearDraft, object: nil)
                }
            } catch {
                self.postStatus(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: - 截图 OCR

    func beginCaptureFromHotKey() {
        statusController?.openPanel(pinned: true)
        beginCapture()
    }

    func beginCapture() {
        guard !isBusy else { return }
        isBusy = true
        onHidePanel?()
        Task { @MainActor in
            self.postStatus("正在截图：框选要识别的内容（Esc 取消）")
            defer { self.isBusy = false }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                let image = try await self.ocr.captureRegionImage()
                self.postStatus("正在识别文字…")
                let text = try await self.ocr.recognizeText(in: image)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.postStatus("截图里没有识别到文字", isError: true)
                    return
                }
                let added = try await self.extractAndStoreReturningCount(text: trimmed, source: .screenshot)
                if added == 0 {
                    self.statusController?.openPanel(pinned: true)
                    self.postStatus("没解析出结构，识别到的文字已填进输入框", isError: true)
                    NotificationCenter.default.post(
                        name: .todoPanelFillDraft, object: nil, userInfo: ["text": trimmed])
                }
            } catch TodoServiceError.captureCancelled {
                self.postStatus("已取消截图")
            } catch {
                self.postStatus(error.localizedDescription, isError: true)
            }
        }
    }

    @discardableResult
    func ingest(text: String, source: TodoSource) async throws -> Int {
        try await extractAndStoreReturningCount(text: text, source: source)
    }

    private func extractAndStoreReturningCount(text: String, source: TodoSource) async throws -> Int {
        let config = settings.settings.ai
        let key = SecretBox.load(account: SecretBox.account(for: config.provider)) ?? ""
        let useRemote = settings.settings.useRemoteModel && !key.isEmpty && config.isRoutable
        let service: AIServicing = useRemote ? remoteAI : localAI
        let parsed = try await service.extractTodos(from: text, now: Date(), config: config, apiKey: key)
        guard !parsed.isEmpty else {
            postStatus("没有解析出待办事项", isError: true)
            return 0
        }
        let added = store.addParsed(parsed, source: source)
        let engine = useRemote ? config.model : "本地规则"
        postStatus("已添加 \(added) 条（\(engine)）")
        return added
    }

    func testAIConnection() async -> String {
        let config = settings.settings.ai
        let key = SecretBox.load(account: SecretBox.account(for: config.provider)) ?? ""
        guard !key.isEmpty else { return "还没保存 API Key" }
        guard config.isRoutable else { return "Base URL 或模型名不合法" }
        do {
            let parsed = try await remoteAI.extractTodos(
                from: "明天上午十点开周会，顺便买咖啡",
                now: Date(),
                config: config,
                apiKey: key
            )
            let preview = parsed.map { todo in
                let time = todo.deadline.map { DeadlineText.absolute($0) } ?? "无截止时间"
                return "\(todo.title)｜\(time)"
            }.joined(separator: "\n")
            return "连接成功（\(config.model)）：\n\(preview)"
        } catch {
            return "连接失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 杂项

    func refreshKeyPresence() {
        let account = SecretBox.account(for: settings.settings.ai.provider)
        keyPresent = !(SecretBox.load(account: account) ?? "").isEmpty
    }

    func registerHotKey() {
        if !hotKey.register(settings.settings.hotkey) {
            postStatus("快捷键注册失败，请换一个组合键", isError: true)
        }
    }

    private func postStatus(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
        if !isError {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.statusMessage == message { self?.statusMessage = nil }
            }
        }
    }

    func openSettings() {
        statusController?.closePanel()
        if settingsWindow == nil {
            let view = SettingsView(app: self, settings: settings)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Todolist 设置"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 520, height: 620))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let snapshotDir = ProcessInfo.processInfo.environment["TODOLIST_SNAPSHOT"], !snapshotDir.isEmpty {
            SnapshotTool.render(into: snapshotDir)
            NSApp.terminate(nil)
            return
        }
        AppController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension Notification.Name {
    static let todoPanelClearDraft = Notification.Name("todoPanelClearDraft")
    static let todoPanelFillDraft = Notification.Name("todoPanelFillDraft")
}
