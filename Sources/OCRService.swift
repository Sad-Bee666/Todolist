import Foundation
import CoreGraphics
import ImageIO
import Vision

/// 屏幕框选 + Vision 文字识别。截图交给系统 screencapture，因此不需要辅助功能权限。
final class ScreenOCRService: OCRServicing {

    private static let screencapturePath = "/usr/sbin/screencapture"

    func captureRegionImage() async throws -> CGImage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("todolist-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try await Self.runScreencapture(to: url)

        // 用户按 Esc 取消时不会留下文件，个别系统版本会留一个 0 字节空文件
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw TodoServiceError.captureCancelled }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TodoServiceError.ocrFailed("截图解码失败：\(url.lastPathComponent)")
        }
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

    /// 阻塞到用户完成框选或按 Esc；退出码不直接决定结果，由调用方按产物判断。
    private static func runScreencapture(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: screencapturePath)
            process.arguments = ["-i", "-x", "-t", "png", url.path]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
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
