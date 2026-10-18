import AppKit

/// 状态栏图标。
///
/// 用 `NSStatusItem` 而不是 SwiftUI 的 `MenuBarExtra` —— 后者无法区分图标的左键和右键，
/// 而菜单栏工具的惯例是「左键开面板，右键出菜单」。
final class StatusItem: NSObject {
    static var shared: StatusItem?

    private let item: NSStatusItem
    private let menu = NSMenu()

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        Self.shared = self
        configure()
    }

    private func configure() {
        let currentIconName = UserDefaults.standard.string(forKey: "ifolo.statusBarIcon") ?? "notebook"
        if let button = item.button {
            button.image = Self.icon(named: currentIconName)
            button.image?.isTemplate = true
            button.toolTip = "iFolo · 屏幕边缘笔记"
            button.target = self
            button.action = #selector(handleClick)
            // 左右键都要收到
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        buildMenu()
    }

    /// 图标生成器：支持 4 款视觉尺寸、线条粗细与随身便签完全一致的标准菜单栏图标
    static func icon(named name: String = "notebook") -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image: NSImage

        switch name {
        case "notepad":
            // 便签本 (对应 notepad.svg：外框 12.5×13.5，线宽 1.2pt，三条横线 1.1pt)
            image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setStroke()
                let body = NSBezierPath(roundedRect: NSRect(x: 2.75, y: 2.25, width: 12.5, height: 13.5), xRadius: 2.0, yRadius: 2.0)
                body.lineWidth = 1.2
                body.stroke()

                let lines: [(CGFloat, CGFloat, CGFloat)] = [
                    (5.5, 11.25, 11.5),
                    (5.5, 12.5, 8.75),
                    (5.5, 9.5, 6.25)
                ]
                for (x1, x2, y) in lines {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: x1, y: y))
                    line.line(to: NSPoint(x: x2, y: y))
                    line.lineWidth = 1.1
                    line.lineCapStyle = .round
                    line.stroke()
                }
                return true
            }

        case "note", "note_pen":
            // 写作笔笺 (对应 note.svg：底本 11.0×12.25，线宽 1.2pt，右上角斜插笔 1.15pt)
            image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setStroke()
                let pad = NSBezierPath()
                pad.move(to: NSPoint(x: 9.0, y: 14.5))
                pad.line(to: NSPoint(x: 4.5, y: 14.5))
                pad.appendArc(from: NSPoint(x: 2.5, y: 14.5), to: NSPoint(x: 2.5, y: 12.5), radius: 2.0)
                pad.line(to: NSPoint(x: 2.5, y: 4.25))
                pad.appendArc(from: NSPoint(x: 2.5, y: 2.25), to: NSPoint(x: 4.5, y: 2.25), radius: 2.0)
                pad.line(to: NSPoint(x: 11.5, y: 2.25))
                pad.appendArc(from: NSPoint(x: 13.5, y: 2.25), to: NSPoint(x: 13.5, y: 4.25), radius: 2.0)
                pad.line(to: NSPoint(x: 13.5, y: 8.5))
                pad.lineWidth = 1.2
                pad.lineCapStyle = .round
                pad.lineJoinStyle = .round
                pad.stroke()

                let l1 = NSBezierPath()
                l1.move(to: NSPoint(x: 5.25, y: 6.0))
                l1.line(to: NSPoint(x: 10.75, y: 6.0))
                l1.lineWidth = 1.0
                l1.lineCapStyle = .round
                l1.stroke()

                let l2 = NSBezierPath()
                l2.move(to: NSPoint(x: 5.25, y: 9.0))
                l2.line(to: NSPoint(x: 8.5, y: 9.0))
                l2.lineWidth = 1.0
                l2.lineCapStyle = .round
                l2.stroke()

                let pen = NSBezierPath()
                pen.move(to: NSPoint(x: 8.5, y: 9.5))
                pen.line(to: NSPoint(x: 10.0, y: 11.5))
                pen.line(to: NSPoint(x: 14.5, y: 16.0))
                pen.line(to: NSPoint(x: 16.0, y: 14.5))
                pen.line(to: NSPoint(x: 11.5, y: 10.0))
                pen.close()
                pen.lineWidth = 1.15
                pen.lineJoinStyle = .round
                pen.stroke()
                return true
            }

        case "note-2", "note2", "memo_board":
            // 备忘板 (对应 note-2.svg：板身 12.5×13.5，线宽 1.2pt，顶梁横线 1.15pt，左下文本，右下时钟圈)
            image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setStroke()
                let board = NSBezierPath(roundedRect: NSRect(x: 2.75, y: 2.25, width: 12.5, height: 13.5), xRadius: 2.0, yRadius: 2.0)
                board.lineWidth = 1.2
                board.stroke()

                let bar = NSBezierPath()
                bar.move(to: NSPoint(x: 2.75, y: 12.5))
                bar.line(to: NSPoint(x: 15.25, y: 12.5))
                bar.lineWidth = 1.15
                bar.stroke()

                let clip = NSBezierPath(roundedRect: NSRect(x: 7.25, y: 13.5, width: 3.5, height: 1.4), xRadius: 0.7, yRadius: 0.7)
                clip.lineWidth = 0.9
                clip.stroke()

                let t1 = NSBezierPath()
                t1.move(to: NSPoint(x: 5.25, y: 8.75))
                t1.line(to: NSPoint(x: 8.75, y: 8.75))
                t1.lineWidth = 1.05
                t1.lineCapStyle = .round
                t1.stroke()

                let t2 = NSBezierPath()
                t2.move(to: NSPoint(x: 5.25, y: 5.75))
                t2.line(to: NSPoint(x: 7.75, y: 5.75))
                t2.lineWidth = 1.05
                t2.lineCapStyle = .round
                t2.stroke()

                let clock = NSBezierPath(ovalIn: NSRect(x: 9.25, y: 3.5, width: 5.0, height: 5.0))
                clock.lineWidth = 1.15
                clock.stroke()

                let hand = NSBezierPath()
                hand.move(to: NSPoint(x: 11.75, y: 6.0))
                hand.line(to: NSPoint(x: 11.75, y: 7.3))
                hand.move(to: NSPoint(x: 11.75, y: 6.0))
                hand.line(to: NSPoint(x: 12.8, y: 6.0))
                hand.lineWidth = 0.9
                hand.lineCapStyle = .round
                hand.stroke()
                return true
            }

        case "notebook", "default":
            fallthrough
        default:
            // 随身便签 (标准基准尺寸：宽 12.0pt，高 13.5pt，线宽 1.2pt，横线 1.0pt)
            image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setStroke()

                let body = NSBezierPath(roundedRect: NSRect(x: 3.0, y: 2.25, width: 12.0, height: 13.5), xRadius: 2.0, yRadius: 2.0)
                body.lineWidth = 1.2
                body.stroke()

                let spine = NSBezierPath()
                spine.move(to: NSPoint(x: 6.0, y: 2.25))
                spine.line(to: NSPoint(x: 6.0, y: 15.75))
                spine.lineWidth = 1.2
                spine.stroke()

                for y in [12.0, 9.0, 6.0] {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: 8.0, y: y))
                    line.line(to: NSPoint(x: 12.5, y: y))
                    line.lineWidth = 1.0
                    line.stroke()
                }
                return true
            }
        }

        image.isTemplate = true
        return image
    }
    /// 即时更新状态栏当前显示的图标
    func updateIcon(named name: String) {
        UserDefaults.standard.set(name, forKey: "ifolo.statusBarIcon")
        if let button = item.button {
            button.image = Self.icon(named: name)
            button.image?.isTemplate = true
        }
        Log.write("菜单栏图标即时更新为: \(name)")
    }

    private func buildMenu() {
        menu.removeAllItems()

        let newNoteItem = menu.addItem(withTitle: "新建笔记", action: #selector(newNote), keyEquivalent: "n")
        newNoteItem.keyEquivalentModifierMask = [.command]
        newNoteItem.target = self

        let noteListItem = menu.addItem(withTitle: "全部笔记", action: #selector(openNoteList), keyEquivalent: "l")
        noteListItem.keyEquivalentModifierMask = [.command]
        noteListItem.target = self

        let cmdPaletteItem = menu.addItem(withTitle: "命令面板", action: #selector(openCommandPalette), keyEquivalent: "k")
        cmdPaletteItem.keyEquivalentModifierMask = [.command]
        cmdPaletteItem.target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "关于 iFolo", action: #selector(showAbout), keyEquivalent: "")
            .target = self

        let quitItem = menu.addItem(withTitle: "退出 iFolo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
    }

    // MARK: - 点击

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isRightClick, let button = item.button {
            buildMenu()
            Log.write("右键：弹出菜单")
            let wasEdgePaused = EdgeTrigger.shared.isPaused
            EdgeTrigger.shared.pause()
            item.popUpMenu(menu)
            button.isHighlighted = false
            if !wasEdgePaused && !PanelController.shared.isVisible {
                EdgeTrigger.shared.resume()
            }
        } else {
            Log.write("左键：切换面板")
            PanelController.shared.toggle()
        }
    }

    // MARK: - 菜单动作

    @objc private func newNote() {
        PanelController.shared.show()
        PanelController.shared.evaluate("window.__ifoloNewNote && window.__ifoloNewNote()")
    }

    @objc private func openNoteList() {
        PanelController.shared.show()
        PanelController.shared.evaluate("window.__ifoloToggleList && window.__ifoloToggleList()")
    }

    @objc private func openCommandPalette() {
        PanelController.shared.show()
        PanelController.shared.evaluate("window.__ifoloCommandPalette && window.__ifoloCommandPalette()")
    }

    @objc private func showAbout() {
        AboutWindowController.shared.show()
    }
}
