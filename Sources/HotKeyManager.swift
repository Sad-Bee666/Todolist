import Foundation
import Carbon.HIToolbox

/// Carbon 全局热键：RegisterEventHotKey 走系统热键通道，不需要辅助功能授权。
final class HotKeyManager {

    /// 触发时在主线程调用。
    var handler: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 四字符签名 'TDLT'，用于过滤属于本类的热键事件。
    private static let signature: OSType = 0x5444_4C54
    private static let identifier = UInt32(1)

    @discardableResult
    func register(_ spec: HotKeySpec) -> Bool {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                hotKeyEventCallback,
                                                1,
                                                &eventType,
                                                Unmanaged.passUnretained(self).toOpaque(),
                                                &handlerRef)
        guard installStatus == noErr, handlerRef != nil else {
            handlerRef = nil
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(spec.keyCode,
                                         spec.carbonModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)
        guard status == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    fileprivate func fire() {
        guard let handler else { return }
        if Thread.isMainThread {
            handler()
        } else {
            DispatchQueue.main.async { handler() }
        }
    }

    deinit {
        unregister()
    }
}

private let hotKeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr, hotKeyID.signature == 0x5444_4C54 else {
        return OSStatus(eventNotHandledErr)
    }

    Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().fire()
    return noErr
}
