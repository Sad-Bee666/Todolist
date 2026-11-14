import Foundation

/// 预留：外部 IM 通道标识。
enum IMChannel: String, Codable, CaseIterable, Identifiable {
    case qq, wechat
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .qq: return "QQ"
        case .wechat: return "微信"
        }
    }
}

struct IMInboundMessage {
    var channel: IMChannel
    var senderID: String
    var senderName: String
    var text: String
    var receivedAt: Date

    init(channel: IMChannel, senderID: String, senderName: String = "", text: String, receivedAt: Date = Date()) {
        self.channel = channel
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.receivedAt = receivedAt
    }
}

struct IMOutboundMessage {
    var channel: IMChannel
    var targetID: String
    var text: String
}

/// 预留：把 IM 文本送进与截图/粘贴完全相同的抽取管线。
protocol TodoIngest: AnyObject {
    @discardableResult
    func ingest(text: String, source: TodoSource) async throws -> Int
}

/// 预留：一个 IM 连接的抽象。QQ / 微信适配器以后只需实现本协议并注册到 IMBridgeRegistry。
protocol IMBridge: AnyObject {
    var channel: IMChannel { get }
    var isRunning: Bool { get }
    var onMessage: ((IMInboundMessage) -> Void)? { get set }
    func start() async throws
    func stop()
    func send(_ message: IMOutboundMessage) async throws
}

/// 预留：QQ 适配器占位（未实现）。接入时在此实现 start/stop/send 并接上 onMessage。
final class QQBridge: IMBridge {
    let channel: IMChannel = .qq
    private(set) var isRunning: Bool = false
    var onMessage: ((IMInboundMessage) -> Void)?

    func start() async throws {
        throw TodoServiceError.notConfigured("QQ 接入尚未实现（预留接口）")
    }
    func stop() { isRunning = false }
    func send(_ message: IMOutboundMessage) async throws {
        throw TodoServiceError.notConfigured("QQ 接入尚未实现（预留接口）")
    }
}

/// 预留：微信适配器占位（未实现）。
final class WeChatBridge: IMBridge {
    let channel: IMChannel = .wechat
    private(set) var isRunning: Bool = false
    var onMessage: ((IMInboundMessage) -> Void)?

    func start() async throws {
        throw TodoServiceError.notConfigured("微信接入尚未实现（预留接口）")
    }
    func stop() { isRunning = false }
    func send(_ message: IMOutboundMessage) async throws {
        throw TodoServiceError.notConfigured("微信接入尚未实现（预留接口）")
    }
}

/// 预留：通道注册表。AppController.start() 会把 ingest 管线接给每个 bridge 的 onMessage。
final class IMBridgeRegistry {
    static let shared = IMBridgeRegistry()
    private var bridges: [IMChannel: IMBridge] = [:]

    func register(_ bridge: IMBridge) { bridges[bridge.channel] = bridge }
    func bridge(for channel: IMChannel) -> IMBridge? { bridges[channel] }
    var channels: [IMChannel] { IMChannel.allCases.filter { bridges[$0] != nil } }
}
