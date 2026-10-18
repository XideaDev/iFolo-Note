import AppKit
import Carbon.HIToolbox

/// 全局快捷键。
///
/// 用 Carbon 的 `RegisterEventHotKey` —— 它不需要「辅助功能」权限，
/// 而 `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` 需要。
/// 对一个随手要按的呼出键来说，要求用户去系统设置里授权是不可接受的。
///
/// ⚠️ 事件处理器必须全局共享一份。
/// 每个 HotKey 实例都调一次 `InstallEventHandler` 会失败：`-9866`（已安装）。
/// 第一次踩到过，第二个快捷键静默注册不上。
final class HotKey {

    private var hotKeyRef: EventHotKeyRef?
    let handler: () -> Void
    let identifier: UInt32

    // 模块级，非 private —— 上面的 Carbon 回调函数要访问它
    static var registry: [UInt32: HotKey] = [:]
    static var nextId: UInt32 = 1
    private static var handlerRef: EventHandlerRef?
    private static var handlerInstalled = false

    /// - Parameters:
    ///   - keyCode: 虚拟键码，如 `kVK_ANSI_N`
    ///   - modifiers: Carbon 修饰键，如 `cmdKey | optionKey`
    ///   - handler: 触发回调（已经在主线程）
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.identifier = HotKey.nextId
        HotKey.nextId += 1

        let status = HotKey.installSharedHandler()
        guard status == noErr else {
            Log.write("快捷键事件处理器安装失败：\(status)")
            return nil
        }

        let hotKeyId = EventHotKeyID(signature: OSType(0x49464C4F), id: identifier) // 'IFLO'
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyId,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard registerStatus == noErr, let ref else {
            Log.write("快捷键注册失败（可能已被占用）：\(registerStatus)")
            return nil
        }

        hotKeyRef = ref
        HotKey.registry[identifier] = self
        Log.write("快捷键已注册 id=\(identifier) keyCode=\(keyCode) modifiers=\(modifiers)")
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        HotKey.registry.removeValue(forKey: identifier)
    }

    private static func installSharedHandler() -> OSStatus {
        guard !handlerInstalled else { return noErr }
        handlerInstalled = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        return InstallEventHandler(
            GetApplicationEventTarget(),
            ifoloHotKeyCallback,
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }
}

/// Carbon 的回调必须是不捕获上下文的可执行函数体，所以放模块级，
/// 通过 hotKeyId 回到注册表里取回实例。
private func ifoloHotKeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var hotKeyId = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyId
    )
    guard status == noErr else { return status }
    if let instance = HotKey.registry[hotKeyId.id] {
        DispatchQueue.main.async { instance.handler() }
    }
    _ = nextHandler
    _ = userData
    return noErr
}

/// Carbon 修饰键常量，方便调用方书写
enum HotKeyModifier {
    static let cmd = UInt32(cmdKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)
    static let shift = UInt32(shiftKey)
}

/// 常用虚拟键码
enum KeyCode {
    static let n = UInt32(kVK_ANSI_N)
    static let m = UInt32(kVK_ANSI_M)
    static let space = UInt32(kVK_Space)
}
