import Foundation
import ServiceManagement

/// 登录时自动启动：用 macOS 13+ 的 SMAppService，注册项会出现在
/// 系统设置 → 通用 → 登录项 里，而不是自己往 LaunchAgents 写 plist。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .notRegistered: return "未开启"
        case .notFound: return "未找到应用（请先装到 /Applications）"
        case .requiresApproval: return "等待系统批准（系统设置 → 通用 → 登录项）"
        @unknown default: return "状态未知"
        }
    }

    /// 成功返回 nil，失败返回错误描述。
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
