import Foundation
import CoreGraphics
import ImageIO
import Vision
import AppKit

/// 屏幕录制权限：必须由应用自己申请，否则子进程 screencapture 会被 TCC 静默拒绝。
enum ScreenCapturePermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 首次调用会弹出系统授权框；用户在系统设置里勾选后通常需重开应用才生效。
    @discardableResult
    static func request() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// 屏幕框选 + Vision 文字识别。截图交给系统 screencapture，因此不需要辅助功能权限。
final class ScreenOCRService: OCRServicing {

    private static let screencapturePath = "/usr/sbin/screencapture"

    /// 截取参数；自检时可替换成 -R 固定区域。
    var captureArguments: [String] = ["-i", "-x"]

    static func captureDirectory() -> URL {
        TodoStore.defaultDirectory().appendingPathComponent("captures", isDirectory: true)
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 近乎纯色的图基本等于「没拿到真实画面」（权限失效时截出来就是黑图）。
    static func isLikelyBlank(_ image: CGImage) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let minValue = pixels.min(), let maxValue = pixels.max() else { return false }
        return Int(maxValue) - Int(minValue) < 8
    }

    func captureRegionImage() async throws -> CGImage {
        let directory = ScreenOCRService.captureDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let stderr = try await Self.runScreencapture(arguments: captureArguments, to: url)

        // 一次性读成内存数据再解码：避免「先查大小、再读盘」之间文件消失的竞态
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            if Self.looksLikePermissionDenial(stderr) {
                throw TodoServiceError.ocrFailed("没有屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制 里勾选 Todolist，然后重开应用")
            }
            throw TodoServiceError.captureCancelled
        }
        guard let image = ScreenOCRService.image(from: data) else {
            throw TodoServiceError.ocrFailed("截图解码失败（\(data.count) 字节）")
        }
        NSLog("[capture] %dx%d %d bytes", image.width, image.height, data.count)
        return image
    }

    func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                continuation.resume(returning: Self.joinedText(from: request.results ?? []))
            } catch {
                continuation.resume(throwing: TodoServiceError.ocrFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - 私有

    private static func looksLikePermissionDenial(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("not authorized")
            || text.contains("cannot capture")
            || text.contains("could not create image")
            || text.contains("denied")
    }

    /// 返回进程的 stderr，便于区分「用户取消」与「权限被拒」。
    private static func runScreencapture(arguments: [String], to url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: screencapturePath)
            process.arguments = arguments + ["-t", "png", url.path]

            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice

            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if finished.terminationStatus != 0 && text.isEmpty {
                    continuation.resume(returning: "screencapture 退出码 \(finished.terminationStatus)")
                } else {
                    continuation.resume(returning: text)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TodoServiceError.ocrFailed(
                    "无法启动 screencapture：\(error.localizedDescription)"))
            }
        }
    }

    /// 按 boundingBox 自上而下分行，行内自左向右，行间用换行连接。
    private static func joinedText(from observations: [VNRecognizedTextObservation]) -> String {
        let topDown = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var lines: [[VNRecognizedTextObservation]] = []

        for observation in topDown {
            let box = observation.boundingBox
            if let reference = lines.last?.first?.boundingBox,
               abs(reference.midY - box.midY) <= max(reference.height, box.height) * 0.5 {
                lines[lines.count - 1].append(observation)
            } else {
                lines.append([observation])
            }
        }

        return lines
            .map { line in
                line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
