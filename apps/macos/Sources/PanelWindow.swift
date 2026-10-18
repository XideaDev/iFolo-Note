import AppKit

/// iFolo 的面板窗口。
///
/// 三个必须遵守的约束（都是实测踩出来的，表现都是「左键点了没反应」或「要点两次」）：
///
/// 1. **`.nonactivatingPanel` 是必须的，不是可选项。**
///    macOS 拒绝从状态栏点击激活一个 accessory App，`NSApp.activate()` 会静默失败。
///    普通 `.borderless` 窗口只有在 App 激活时才能成为 key，于是面板永远不是 key，
///    用户打开面板后的第一次点击会被系统吃掉用于聚焦窗口 —— 表现为「每个操作都要点两次」。
///    `.nonactivatingPanel` 是唯一能在 App 未激活时拿到 key 的窗口类型。
///
/// 2. **用 `orderFrontRegardless()`，不要 `makeKeyAndOrderFront()`。**
///    后者在 App 非激活时会直接拒绝显示。
///
/// 3. **`makeKey()` 要重试。** 窗口刚 order front 时第一次调用可能是空操作。
///    判断依据用 `panel.isKeyWindow`，不要用 `NSApp.isActive`（accessory App 可能永远不 active）。
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 处理非激活浮动面板内的标准编辑快捷键（复制、粘贴、全选、剪切、撤销）
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "v" {
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) {
                    return true
                }
            } else if key == "c" {
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) {
                    return true
                }
            } else if key == "x" {
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) {
                    return true
                }
            } else if key == "a" {
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) {
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
