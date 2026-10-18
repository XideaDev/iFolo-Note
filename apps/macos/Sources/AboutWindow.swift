import AppKit

/// iFolo Note 精致关于弹窗
///
private class AboutPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        self.close()
    }
}

/// iFolo Note 精致关于弹窗
///
/// 遵循 macOS HIG 规范，采用匀称紧凑的 290×248 紧凑布局，
/// 消除原生 NSAlert 的冗余外边距与横向空隙，层级清晰精致。
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()
    private init() {
        let width: CGFloat = 290
        let height: CGFloat = 248

        let panel = AboutPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .alertPanel

        // 毛玻璃磨砂背景
        let visualEffect = NSVisualEffectView(frame: panel.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        panel.contentView?.addSubview(visualEffect)

        // 1. 应用图标 52×52
        let iconSize: CGFloat = 52
        let iconView = NSImageView(frame: NSRect(x: (width - iconSize) / 2, y: height - 20 - iconSize, width: iconSize, height: iconSize))
        if let icon = NSApp.applicationIconImage ?? Bundle.main.image(forResource: "AppIcon") {
            iconView.image = icon
        }
        visualEffect.addSubview(iconView)

        // 2. 主标题
        let titleLabel = NSTextField(labelWithString: "iFolo Note")
        titleLabel.frame = NSRect(x: 16, y: height - 20 - iconSize - 8 - 20, width: width - 32, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        titleLabel.alignment = .center
        visualEffect.addSubview(titleLabel)

        // 3. 副标题与版本号
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"
        let subLabel = NSTextField(labelWithString: "心流笔记 · v\(version)")
        subLabel.frame = NSRect(x: 16, y: height - 20 - iconSize - 8 - 20 - 16, width: width - 32, height: 16)
        subLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        subLabel.textColor = NSColor.secondaryLabelColor
        subLabel.alignment = .center
        visualEffect.addSubview(subLabel)

        // 4. 精炼产品介绍（两行，紧凑舒适）
        let desc = NSTextField(wrappingLabelWithString: "专为 Mac 设计的轻盈边缘便签与心流写作工具\n触碰边缘即刻唤起 · 纯本地 Markdown 安全存储")
        desc.frame = NSRect(x: 16, y: 72, width: width - 32, height: 32)
        desc.font = NSFont.systemFont(ofSize: 11)
        desc.textColor = NSColor.secondaryLabelColor
        desc.alignment = .center
        visualEffect.addSubview(desc)

        // 5. 官网链接按钮
        let webBtn = NSButton(frame: NSRect(x: (width - 120) / 2, y: 44, width: 120, height: 18))
        webBtn.title = "www.ifolo.cn ↗"
        webBtn.bezelStyle = .inline
        webBtn.isBordered = false
        webBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        webBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        webBtn.contentTintColor = NSColor.systemBlue
        visualEffect.addSubview(webBtn)

        // 6. 确定关闭按钮
        let doneBtn = NSButton(frame: NSRect(x: (width - 72) / 2, y: 14, width: 72, height: 22))
        doneBtn.title = "好"
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        visualEffect.addSubview(doneBtn)

        super.init(window: panel)

        webBtn.target = self
        webBtn.action = #selector(openWebsite)
        doneBtn.target = self
        doneBtn.action = #selector(closeAbout)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openWebsite() {
        if let url = URL(string: "https://www.ifolo.cn") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func closeAbout() {
        window?.close()
    }
}
