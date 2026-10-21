import AppKit

/// iFolo macOS 外壳入口。
///
/// 用自定义 `main()` 而不是 `@main` + SwiftUI App —— 我们需要 `NSStatusItem` 的
/// 左右键分流，而 `MenuBarExtra` 做不到。
@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItem?
    private var edgeTrigger: EdgeTrigger?
    private var hotKeys: [HotKey] = []

    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            // 启用无头 MCP 模式（通过 stdio 提供服务，无任何窗口与图标占用）
            MCPServer.shared.startStdio()
            RunLoop.main.run()
            return
        }

        UserDefaults.standard.register(defaults: [
            "AppleLanguages": ["zh-Hans", "zh_CN", "en"]
        ])

        let app = NSApplication.shared
        // NSApplication.delegate 是 weak，必须自己持有强引用
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        setupMainMenu()
        app.run()
    }

    /// 设置基础编辑主菜单（保证 accessory 常驻后台 App 中 ⌘V 粘贴、⌘C 复制、⌘A 全选等剪贴板动作正常路由至 WKWebView）
    private static func setupMainMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.rotateIfNeeded()
        Log.write("──────── iFolo 启动 v\(Self.version) ────────")
        Log.write("语言偏好: preferred=\(Bundle.main.preferredLocalizations), localizations=\(Bundle.main.localizations)")
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let appIcon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = appIcon
        }

        // 定时器与监听必须在 didFinishLaunching 里起，不要放进任何视图的 onAppear
        statusItem = StatusItem()

        let trigger = EdgeTrigger.shared
        trigger.zoneWidth = 8
        let savedDelay = UserDefaults.standard.object(forKey: "ifolo.edgeHoverDelay") as? Double ?? 0.15
        trigger.dwell = max(0.05, min(2.0, savedDelay))
        trigger.start()
        edgeTrigger = trigger

        registerHotKeys()

        // 监听跨进程分布式通知（支持 MCP CLI、外部脚本触发的数据变动）通知前端实时刷新
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("iFoloDataChangedExternally"), object: nil, queue: .main) { _ in
            PanelController.shared.evaluate("window.__ifoloRefreshNotes && window.__ifoloRefreshNotes()")
        }

        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("iFoloCheckForUpdates"), object: nil, queue: .main) { _ in
            UpdateManager.shared.checkForUpdates()
        }

        // 预热本地向量检索引擎
        SearchEngine.shared.warmup(notes: Store.shared.listNotes())

        // 启动 Sparkle 2 自动更新引擎
        UpdateManager.shared.start()

        // 首次启动时把面板亮一下，让用户知道它在哪
        if !UserDefaults.standard.bool(forKey: "ifolo.hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "ifolo.hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Log.write("首次启动，自动展开面板")
                PanelController.shared.show()
            }
        }

        Telemetry.shared.track(name: "app_launched", properties: [
            "edge_delay": trigger.dwell,
        ])
        Log.write("启动完成：状态栏图标已就位，边缘触发已启动，快捷键已注册")
    }

    private func registerHotKeys() {
        // ⌥⌘N 呼出 / 收起面板
        if let toggle = HotKey(
            keyCode: KeyCode.n,
            modifiers: HotKeyModifier.option | HotKeyModifier.cmd,
            handler: {
                Log.write("快捷键：切换面板")
                PanelController.shared.toggle()
            }
        ) {
            hotKeys.append(toggle)
        } else {
            Log.write("⌥⌘N 注册失败（可能被占用）")
        }

        // ⌥⌘M 新建快速笔记
        if let newNote = HotKey(
            keyCode: KeyCode.m,
            modifiers: HotKeyModifier.option | HotKeyModifier.cmd,
            handler: {
                Log.write("快捷键：新建笔记")
                PanelController.shared.newQuickNote()
            }
        ) {
            hotKeys.append(newNote)
        } else {
            Log.write("⌥⌘M 注册失败（可能被占用）")
        }

        // ⌥⌘P 切换窗口置顶
        if let pin = HotKey(
            keyCode: KeyCode.p,
            modifiers: HotKeyModifier.option | HotKeyModifier.cmd,
            handler: {
                Log.write("快捷键：切换窗口置顶")
                PanelController.shared.toggleAlwaysOnTop()
            }
        ) {
            hotKeys.append(pin)
        } else {
            Log.write("⌥⌘P 注册失败（可能被占用）")
        }

        // ⌥⌘L 即时闭锁私密保险箱
        if let lock = HotKey(
            keyCode: KeyCode.l,
            modifiers: HotKeyModifier.option | HotKeyModifier.cmd,
            handler: {
                Log.write("快捷键：即时闭锁私密保险箱")
                NoteLockManager.shared.lockSession()
                PanelController.shared.evaluate("window.__ifoloLockVault && window.__ifoloLockVault()")
            }
        ) {
            hotKeys.append(lock)
        } else {
            Log.write("⌥⌘L 注册失败（可能被占用）")
        }
    }

    /// 附属 App：关掉窗口不能把状态栏图标一起带走
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.write("iFolo 退出")
        NoteLockManager.shared.lockSession()
        edgeTrigger?.stop()
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
