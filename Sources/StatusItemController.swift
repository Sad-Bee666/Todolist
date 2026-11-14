import AppKit

/// 菜单栏图标 + 下拉面板：鼠标移入自动展开，移出自动收起；点一下钉住/取消。
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hoverEnabled: () -> Bool
    private let closeDelay: () -> Double

    private var hoverTimer: Timer?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var pinned = false
    private var hoverExitAt: Date?
    /// 菜单（模型下拉等）打开期间不按悬停收起面板：菜单是独立窗口，不在图标/面板矩形内。
    private var isTrackingMenu = false

    var onWillOpen: (() -> Void)?

    /// 供自检使用：面板当前是否展开。
    var isPanelVisible: Bool { popover.isShown }

    init(contentViewController: NSViewController,
         hoverEnabled: @escaping () -> Bool,
         closeDelay: @escaping () -> Double) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.hoverEnabled = hoverEnabled
        self.closeDelay = closeDelay
        super.init()

        popover.contentViewController = contentViewController
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    func install() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Todolist")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Todolist — 悬停展开"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        startHoverTimer()
        installClickMonitor()
        installKeyMonitor()
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBeganTracking), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuEndedTracking), name: NSMenu.didEndTrackingNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let frame = self?.statusButtonScreenFrame() {
                NSLog("[panel] statusFrame=%.1f,%.1f,%.1f,%.1f",
                      frame.origin.x, frame.origin.y, frame.width, frame.height)
            }
        }
    }

    // MARK: - 面板开合

    func openPanel(pinned: Bool) {
        self.pinned = pinned
        hoverExitAt = nil
        onWillOpen?()
        NSLog("[panel] open pinned=\(pinned)")
        if !popover.isShown, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if pinned {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePanel() {
        pinned = false
        hoverExitAt = nil
        if popover.isShown {
            NSLog("[panel] close")
            popover.performClose(nil)
        }
    }

    @objc private func statusButtonClicked(_ sender: Any?) {
        if popover.isShown {
            if pinned {
                closePanel()
            } else {
                openPanel(pinned: true)
            }
        } else {
            openPanel(pinned: true)
        }
    }

    // MARK: - 悬停监听

    private func startHoverTimer() {
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let buttonFrame = statusButtonScreenFrame()
        let insideButton = buttonFrame?.contains(point) ?? false

        guard popover.isShown else {
            if hoverEnabled() && insideButton && buttonFrame != nil {
                openPanel(pinned: false)
            }
            return
        }

        if isTrackingMenu {
            hoverExitAt = nil
            return
        }
        if pinned { return }

        let panelFrame = popover.contentViewController?.view.window?.frame
        let insidePanel = panelFrame?.contains(point) ?? false
        if insideButton || insidePanel {
            hoverExitAt = nil
            return
        }
        if let exitAt = hoverExitAt {
            if Date().timeIntervalSince(exitAt) >= closeDelay() { closePanel() }
        } else {
            hoverExitAt = Date()
        }
    }

    var statusButtonScreenFrameForTesting: NSRect? { statusButtonScreenFrame() }

    private func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let inWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    private func installClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            let point = NSEvent.mouseLocation
            let insideButton = self.statusButtonScreenFrame()?.contains(point) ?? false
            let insidePanel = self.popover.contentViewController?.view.window?.frame.contains(point) ?? false
            if !insideButton && !insidePanel { self.closePanel() }
        }
    }

    private func installKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.keyCode == 53 {
                self.closePanel()
                return nil
            }
            return event
        }
    }

    @objc private func menuBeganTracking() {
        isTrackingMenu = true
        hoverExitAt = nil
    }

    @objc private func menuEndedTracking() {
        isTrackingMenu = false
        hoverExitAt = Date()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hoverTimer?.invalidate()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}
