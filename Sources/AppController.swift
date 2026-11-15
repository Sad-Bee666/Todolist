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
        migrateLegacyKeysIfNeeded()
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

    var activeProfile: APIProfile? { settings.settings.activeProfile }

    /// 真正生效的远端判定：开关打开 + 当前配置有 Key + 接口可路由。
    var usesRemoteModel: Bool {
        settings.settings.useRemoteModel && keyPresent && settings.settings.ai.isRoutable
    }

    var modelLabel: String {
        guard settings.settings.useRemoteModel else { return "本地规则" }
        let model = settings.settings.ai.model
        guard !model.isEmpty else { return "选择模型" }
        return keyPresent ? model : model + " · 缺 Key"
    }

    // MARK: - API 配置管理

    func config(for profileID: UUID) -> AIConfig {
        settings.settings.profiles.first { $0.id == profileID }?.config ?? settings.settings.ai
    }

    func key(for profileID: UUID) -> String {
        SecretBox.load(account: SecretBox.account(forProfile: profileID)) ?? ""
    }

    func saveKey(_ value: String, for profileID: UUID) {
        SecretBox.save(value, account: SecretBox.account(forProfile: profileID))
        if settings.settings.activeProfileID == profileID { refreshKeyPresence() }
    }

    func deleteKey(for profileID: UUID) {
        SecretBox.delete(account: SecretBox.account(forProfile: profileID))
        if settings.settings.activeProfileID == profileID { refreshKeyPresence() }
    }

    @discardableResult
    func addProfile() -> UUID {
        let profile = APIProfile(name: "API " + String(settings.settings.profiles.count + 1))
        settings.settings.profiles.append(profile)
        return profile.id
    }

    func deleteProfile(_ profileID: UUID) {
        guard settings.settings.profiles.count > 1 else {
            postStatus("至少保留一份 API 配置", isError: true)
            return
        }
        settings.settings.profiles.removeAll { $0.id == profileID }
        SecretBox.delete(account: SecretBox.account(forProfile: profileID))
        if settings.settings.activeProfileID == profileID {
            settings.settings.activeProfileID = settings.settings.profiles.first?.id
        }
        refreshKeyPresence()
    }

    func setActiveProfile(_ profileID: UUID) {
        settings.settings.activeProfileID = profileID
        refreshKeyPresence()
        postStatus("当前 API：" + (activeProfile?.name ?? "-"))
    }

    func migrateLegacyKeysIfNeeded() {
        var migrated = false
        for profile in settings.settings.profiles {
            if SecretBox.migrateKeyIfNeeded(from: profile.provider, toProfile: profile.id) {
                migrated = true
            }
        }
        if migrated || !settings.settings.migratedLegacyKeys {
            settings.settings.migratedLegacyKeys = true
        }
        refreshKeyPresence()
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

    /// 面板上选择本次调用哪个模型（多选列表里的一个）。
    func useModel(_ name: String) {
        guard let index = settings.settings.profiles.firstIndex(where: { $0.id == settings.settings.activeProfile?.id }) else { return }
        var profile = settings.settings.profiles[index]
        profile.model = name
        if !profile.models.contains(name) { profile.models.append(name) }
        settings.settings.profiles[index] = profile
        settings.settings.useRemoteModel = true
        refreshKeyPresence()
        if keyPresent {
            postStatus("已切换到 " + name)
        } else {
            postStatus("已选 " + name + "，还缺该 API 的 Key", isError: true)
        }
    }

    func makeActions() -> PanelActions {
        PanelActions(
            addManual: { [weak self] text in self?.addManual(text: text) },
            toggleDone: { [weak self] id in self?.store.toggleDone(id: id) },
            deleteItem: { [weak self] id in self?.store.remove(id: id) },
            startCapture: { [weak self] in self?.beginCapture() },
            importScreenshot: { [weak self] in self?.importLatestScreenshot() },
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
        if !ScreenCapturePermission.isGranted && !ScreenCapturePermission.request() {
            postStatus("没有屏幕录制权限。去「系统设置 → 隐私与安全性 → 屏幕录制」勾选 Todolist 并重开应用；或用 ⇧⌘4 截图后点「导入最近截图」", isError: true)
            ScreenCapturePermission.openSystemSettings()
            return
        }
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
                NSLog("[capture] ocr_chars=%d", trimmed.count)
                guard !trimmed.isEmpty else {
                    if ScreenOCRService.isLikelyBlank(image) {
                        self.postStatus("截到的是空白图，说明屏幕录制权限没生效：系统设置 → 隐私与安全性 → 屏幕录制 里重新勾选 Todolist，退出并重开应用", isError: true)
                    } else {
                        self.postStatus("截图里没有识别到文字", isError: true)
                    }
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
        let key = activeProfile.map { self.key(for: $0.id) } ?? ""
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

    /// 保存 Key 后的连通性测试：优先 /models（顺带拿到可用模型），失败再退回一次对话探测。
    func probeConnection(profileID: UUID? = nil) async -> (models: [String], message: String) {
        let targetID = profileID ?? settings.settings.activeProfileID ?? UUID()
        let config = self.config(for: targetID)
        let key = self.key(for: targetID)
        guard !key.isEmpty else { return ([], "还没填 API Key") }
        guard config.isRoutable else { return ([], "Base URL 或模型名不合法") }

        do {
            let models = try await remoteAI.listModels(config: config, apiKey: key)
            return (models, "连通正常，该接口返回 \(models.count) 个可用模型")
        } catch {
            let listError = error.localizedDescription
            do {
                _ = try await remoteAI.extractTodos(
                    from: "明天上午十点开会", now: Date(), config: config, apiKey: key)
                return ([], "对话接口可用，但拉不到模型列表：\(listError)")
            } catch {
                return ([], "连接失败：\(error.localizedDescription)")
            }
        }
    }

    /// 剪贴板里像不像一个 API Key（单行、无空白、长度合理、字符合法）。
    static func keyCandidate(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...300).contains(trimmed.count) else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    /// 读剪贴板并返回可用的 Key 候选。
    func keyFromPasteboard() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        return AppController.keyCandidate(from: raw)
    }

    func testAIConnection(profileID: UUID? = nil) async -> String {
        let targetID = profileID ?? settings.settings.activeProfileID ?? UUID()
        let config = self.config(for: targetID)
        let key = self.key(for: targetID)
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

    /// 自检：整屏抓一张，报告尺寸 / 是否空白 / 识别到多少字，用来判断权限是否真的生效。
    func diagnoseCapture() async -> String {
        guard ScreenCapturePermission.isGranted else {
            return "未授权：系统设置 → 隐私与安全性 → 屏幕录制 里勾选 Todolist，退出并重开应用"
        }
        let service = ScreenOCRService()
        service.captureArguments = ["-x", "-m"]
        do {
            let image = try await service.captureRegionImage()
            let blank = ScreenOCRService.isLikelyBlank(image)
            let text = try await service.recognizeText(in: image)
            let chars = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            let blankText = blank ? "是" : "否"
            return "截图 " + String(image.width) + "×" + String(image.height)
                + "，空白图=" + blankText
                + "，识别到 " + String(chars) + " 个字符"
        } catch {
            return "截图失败：" + error.localizedDescription
        }
    }

    // MARK: - 导入系统截图（不需要屏幕录制权限）

    /// 桌面里最近的一张系统截图（⇧⌘4 / ⇧⌘5 的产物）。
    static func newestSystemScreenshot() -> URL? {
        let fm = FileManager.default
        guard let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else { return nil }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: desktop, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let prefixes = ["屏幕快照", "Screenshot", "截屏", "截圖", "スクリーンショット"]
        let candidates = files.filter { url in
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "heic", "tiff"].contains(ext) else { return false }
            let name = url.lastPathComponent
            return prefixes.contains { name.hasPrefix($0) }
        }
        return candidates.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return l < r
        }
    }

    /// 用系统截图工具（⇧⌘4）产出的文件走同一条 OCR + 解析管线，绕开屏幕录制权限。
    func importLatestScreenshot() {
        guard !isBusy else { return }
        guard let url = AppController.newestSystemScreenshot() else {
            postStatus("桌面没找到系统截图。按 ⇧⌘4 截一张，再点这里", isError: true)
            return
        }
        Task { @MainActor in
            self.isBusy = true
            defer { self.isBusy = false }
            self.postStatus("正在识别 " + url.lastPathComponent + "…")
            guard let image = ScreenOCRService.image(at: url) else {
                self.postStatus("读不了这张图：" + url.lastPathComponent, isError: true)
                return
            }
            do {
                let text = try await self.ocr.recognizeText(in: image)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.postStatus("这张截图里没有识别到文字", isError: true)
                    return
                }
                let added = try await self.extractAndStoreReturningCount(text: trimmed, source: .screenshot)
                if added == 0 {
                    self.statusController?.openPanel(pinned: true)
                    self.postStatus("没解析出结构，识别到的文字已填进输入框", isError: true)
                    NotificationCenter.default.post(
                        name: .todoPanelFillDraft, object: nil, userInfo: ["text": trimmed])
                }
            } catch {
                self.postStatus(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: - 杂项

    func refreshKeyPresence() {
        guard let id = settings.settings.activeProfile?.id else {
            keyPresent = false
            return
        }
        keyPresent = !key(for: id).isEmpty
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
            window.setContentSize(NSSize(width: 580, height: 640))
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
        if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--login-item") }) {
            let result: String
            switch flag {
            case "--login-item-on":
                result = LaunchAtLogin.setEnabled(true).map { "开启失败：" + $0 } ?? "已开启"
            case "--login-item-off":
                result = LaunchAtLogin.setEnabled(false).map { "关闭失败：" + $0 } ?? "已关闭"
            default:
                result = "当前状态：" + LaunchAtLogin.statusText
            }
            let line = result + "（isEnabled=" + String(LaunchAtLogin.isEnabled) + "）"
            try? line.write(to: TodoStore.defaultDirectory().appendingPathComponent("login-item.txt"),
                            atomically: true, encoding: .utf8)
            NSLog("[login-item] " + line)
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in
                let result = await AppController.shared.diagnoseCapture()
                let path = TodoStore.defaultDirectory().appendingPathComponent("selftest.txt")
                try? result.write(to: path, atomically: true, encoding: .utf8)
                NSLog("[selftest] " + result)
                NSApp.terminate(nil)
            }
            return
        }
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
