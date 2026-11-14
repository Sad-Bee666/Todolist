import AppKit
import SwiftUI

/// 把面板与设置窗渲染成无背景 PNG（透明画布 + 圆角卡片），用于 README 与界面验收。
enum SnapshotTool {
    private static let scale: CGFloat = 2
    private static let padding: CGFloat = 26

    static func render(into directory: String) {
        let app = AppController.shared
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        NSApp.appearance = NSAppearance(named: .aqua)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            let populated = TodoPanelView(store: app.store, app: app, actions: app.makeActions())
            write(populated, size: NSSize(width: 380, height: 520), to: dir.appendingPathComponent("panel.png"))

            let emptyStore = TodoStore(directory: dir.appendingPathComponent(".empty-store", isDirectory: true))
            let empty = TodoPanelView(store: emptyStore, app: app, actions: app.makeActions())
            write(empty, size: NSSize(width: 380, height: 520), to: dir.appendingPathComponent("panel-empty.png"))

            let settings = SettingsView(app: app, settings: app.settings)
            write(settings, size: NSSize(width: 520, height: 620), to: dir.appendingPathComponent("settings.png"))
        }

        NSLog("[snapshot] written to \(dir.path)")
    }

    private static func write<V: View>(_ view: V, size: NSSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let inner = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: inner)
        let innerImage = NSImage(size: size)
        innerImage.addRepresentation(inner)

        let canvas = NSSize(width: size.width + padding * 2, height: size.height + padding * 2)
        let pixelsWide = Int(canvas.width * scale)
        let pixelsHigh = Int(canvas.height * scale)
        guard let canvasRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        canvasRep.size = canvas

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvasRep)
        NSColor.clear.set()
        NSRect(origin: .zero, size: canvas).fill()

        let panelRect = NSRect(x: padding, y: padding, width: size.width, height: size.height)
        let card = NSBezierPath(roundedRect: panelRect, xRadius: 12, yRadius: 12)

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.set()
        card.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        NSColor.white.set()
        panelRect.fill()
        innerImage.draw(in: panelRect)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()

        guard let png = canvasRep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
