import AppKit
import SwiftUI

/// 把面板与设置窗直接渲染成 PNG，用于无屏幕录制权限时的界面验收。
enum SnapshotTool {
    static func render(into directory: String) {
        let app = AppController.shared
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let populated = TodoPanelView(store: app.store, app: app, actions: app.makeActions())
        write(populated, size: NSSize(width: 380, height: 520), to: dir.appendingPathComponent("panel-populated.png"))

        let emptyStore = TodoStore(directory: dir.appendingPathComponent(".empty-store", isDirectory: true))
        let empty = TodoPanelView(store: emptyStore, app: app, actions: app.makeActions())
        write(empty, size: NSSize(width: 380, height: 520), to: dir.appendingPathComponent("panel-empty.png"))

        let settings = SettingsView(app: app, settings: app.settings)
        write(settings, size: NSSize(width: 520, height: 620), to: dir.appendingPathComponent("settings.png"))

        NSLog("[snapshot] written to \(dir.path)")
    }

    private static func write<V: View>(_ view: V, size: NSSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let appearance = NSAppearance(named: .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
    }
}
