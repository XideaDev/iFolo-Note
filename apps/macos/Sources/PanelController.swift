import AppKit
import WebKit

/// 面板控制器 —— 负责面板的创建、显隐、定位，以及 Web 内容与原生之间的消息桥。
final class PanelController: NSObject, WKUIDelegate {

    static let shared = PanelController()

    private var panel: PanelWindow?
    private var webView: WKWebView?
    private var outsideMonitor: Any?
    private var installOutsideTask: DispatchWorkItem?
    private var spaceObserver: NSObjectProtocol?
    /// 计算当前允许的最大宽度（分屏能力上限提升到 62% 屏宽，至少 900pt，上限 1200pt）
    func maxAllowedWidth(on screen: NSScreen? = nil) -> CGFloat {
        let scr = screen ?? targetScreen()
        let wide = floor(scr.visibleFrame.width * 0.62)
        return max(900, min(1200, wide))
    }

    /// 面板尺寸。宽度支持 320–(屏幕一半) 可调，默认 432
    var currentWidth: CGFloat {
        let val = UserDefaults.standard.double(forKey: "ifolo.panelWidth")
        let maxW = maxAllowedWidth()
        return val >= 320 && val <= maxW ? CGFloat(val) : 450
    }

    private var panelWidth: CGFloat {
        get { currentWidth }
        set {
            let maxW = maxAllowedWidth()
            let clamped = min(maxW, max(320, newValue))
            UserDefaults.standard.set(Double(clamped), forKey: "ifolo.panelWidth")
        }
    }
    private let topInset: CGFloat = 0
    private let bottomInset: CGFloat = 0
    private let edgeGap: CGFloat = 0
    private let cornerRadius: CGFloat = 16

    /// 窗口全局置顶状态（Always On Top）
    var isAlwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "ifolo.alwaysOnTop") }
        set {
            UserDefaults.standard.set(newValue, forKey: "ifolo.alwaysOnTop")
            updateWindowLevel()
        }
    }

    private override init() {
        super.init()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSpaceChange()
        }
    }

    deinit {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    private func handleSpaceChange() {
        guard let panel else { return }
        Log.write("感知到活动桌面 (Space) 切换: isVisible=\(panel.isVisible)")
        if panel.isVisible {
            // 在新 Space 下重新适应物理尺寸与位置
            reposition(panel)
            // 确保窗口在目标 Space 渲染树中保持可见
            panel.orderFrontRegardless()
            // 重新挂载外部点击监听
            scheduleOutsideMonitor()
            takeKey()
        } else {
            // 确保边缘触发在新桌面武装就绪
            EdgeTrigger.shared.resume()
        }
    }

    func updateWindowLevel() {
        guard let panel else { return }
        if isAlwaysOnTop {
            panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        } else {
            panel.level = .floating
        }
        Log.write("面板置顶状态更新: isAlwaysOnTop=\(isAlwaysOnTop), level=\(panel.level.rawValue)")
    }

    /// 切换窗口全局置顶状态
    /// 切换窗口全局置顶状态
    func toggleAlwaysOnTop() {
        isAlwaysOnTop = !isAlwaysOnTop
        Telemetry.shared.track(name: "always_on_top_toggled", properties: ["is_always_on_top": isAlwaysOnTop])
        evaluate("window.__ifoloSyncAlwaysOnTop && window.__ifoloSyncAlwaysOnTop(\(isAlwaysOnTop))")
    }

    // MARK: - 显隐

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard let panel else {
            Log.write("面板尚未创建，先创建")
            createPanel()
            show()
            return
        }

        // 面板已显示期间暂停边缘触发，避免重复计时
        EdgeTrigger.shared.pause()

        reposition(panel)
        panel.orderFrontRegardless()
        takeKey()
        scheduleOutsideMonitor()
        webView?.evaluateJavaScript("window.__ifoloRefreshNotes && window.__ifoloRefreshNotes(); window.__ifoloFocus && window.__ifoloFocus(); window.__ifoloWindowActivated && window.__ifoloWindowActivated();")
        updateWindowLevel()
    }

    func hide() {
        guard let panel else { return }
        removeOutsideMonitor()
        panel.orderOut(nil)
        // 面板收起后，恢复屏幕边缘触发监听
        EdgeTrigger.shared.resume()
        Log.write("面板隐藏")
    }

    /// 窗口刚 order front 时第一次 makeKey() 可能是空操作，所以要重试。
    /// 判断依据用 panel.isKeyWindow —— accessory App 可能永远不 active，用 NSApp.isActive 会误判。
    private func takeKey(attempt: Int = 0) {
        guard let panel, panel.isVisible else { return }
        panel.makeKey()
        if panel.isKeyWindow { return }
        guard attempt < 12 else {
            Log.write("面板始终未能成为 key（尝试 \(attempt) 次）")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.takeKey(attempt: attempt + 1)
        }
    }

    // MARK: - 创建

    private func targetScreen() -> NSScreen {
        let mouseLoc = NSEvent.mouseLocation
        if let screenUnderMouse = NSScreen.screens.first(where: {
            mouseLoc.x >= $0.frame.minX && mouseLoc.x <= $0.frame.maxX &&
            mouseLoc.y >= $0.frame.minY && mouseLoc.y <= $0.frame.maxY
        }) {
            return screenUnderMouse
        }
        return NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func createPanel() {
        let screen = targetScreen()
        let rect = panelRect(on: screen)

        let window = PanelWindow(contentRect: rect)
        let web = makeWebView(frame: NSRect(origin: .zero, size: rect.size))

        window.contentView = web
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = cornerRadius
        window.contentView?.layer?.masksToBounds = true
        window.setContentSize(rect.size)

        panel = window
        webView = web
        loadEditor(into: web)
        updateWindowLevel()
    }

    private func makeWebView(frame: NSRect) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(MessageBridge.shared, name: "ifolo")
        config.userContentController = controller

        let web = WKWebView(frame: frame, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.allowsLinkPreview = false
        web.wantsLayer = true
        web.layer?.cornerRadius = cornerRadius
        web.layer?.masksToBounds = true
        return web
    }

    private func loadEditor(into web: WKWebView) {
        guard let resources = Bundle.main.resourceURL else {
            Log.write("找不到 Resources 目录")
            return
        }
        let dist = resources.appendingPathComponent("editor", isDirectory: true)
        let index = dist.appendingPathComponent("index.html")

        guard FileManager.default.fileExists(atPath: index.path) else {
            Log.write("编辑器产物不存在：\(index.path)")
            web.loadHTMLString(Self.missingEditorHTML, baseURL: nil)
            return
        }

        web.loadFileURL(index, allowingReadAccessTo: dist)
        Log.write("已加载编辑器：\(index.path)")
    }

    // MARK: - 定位

    private func panelRect(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let maxW = maxAllowedWidth(on: screen)
        let actualWidth = min(maxW, max(320, panelWidth))
        let height = visible.height - topInset - bottomInset
        return NSRect(
            x: visible.maxX - actualWidth - edgeGap,
            y: visible.minY + bottomInset,
            width: actualWidth,
            height: max(320, height)
        )
    }

    private func reposition(_ panel: PanelWindow) {
        let screen = targetScreen()
        panel.setFrame(panelRect(on: screen), display: false)
    }

    // MARK: - 点外部收起
    private func scheduleOutsideMonitor() {
        installOutsideTask?.cancel()
        removeOutsideMonitor()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.installOutsideMonitor()
        }
        installOutsideTask = task
        // 延迟 180ms 挂载，彻底避开呼出动作期间鼠标点击的物理释放与微颤
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private func installOutsideMonitor() {
        guard outsideMonitor == nil, isVisible else { return }
        // 全局监听不会收到发给本 App 的事件，所以面板内部的点击天然被忽略
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self = self else { return }
            // 全局置顶模式下钉在桌面最前，点击外部不触发收起
            if self.isAlwaysOnTop { return }
            // 过滤：如果点击位置位于面板窗口本身或状态栏菜单区域，不触发外部收起
            if let panel = self.panel {
                let loc = NSEvent.mouseLocation
                if panel.frame.contains(loc) { return }
                if let scr = panel.screen, loc.y >= (scr.frame.maxY - 32) && loc.x >= (scr.frame.maxX - 200) {
                    return
                }
            }
            // 判断是否启用失焦自动隐藏（默认 true，若用户关闭则不收起）
            let autoHide = UserDefaults.standard.object(forKey: "ifolo.autoHide") as? Bool ?? true
            if autoHide {
                self.hide()
            }
        }
    }

    private func removeOutsideMonitor() {
        installOutsideTask?.cancel()
        installOutsideTask = nil
        if let monitor = outsideMonitor {
            NSEvent.removeMonitor(monitor)
            outsideMonitor = nil
        }
    }
    // MARK: - 供 Bridge 调用

    func evaluate(_ js: String) {
        webView?.evaluateJavaScript(js)
    }

    /// ⌥⌘M：展开面板并新建一条快速笔记
    func newQuickNote() {
        if !isVisible { show() }
        evaluate("window.__ifoloFocus && window.__ifoloFocus(); window.__ifoloNewNote && window.__ifoloNewNote()")
        Log.write("请求新建快速笔记")
    }

    /// 原生快捷键关闭当前编辑标签页 (⌘W)
    func closeCurrentTab() {
        evaluate("window.__ifoloCloseCurrentTab && window.__ifoloCloseCurrentTab()")
        Log.write("请求关闭当前编辑标签页")
    }
    /// 调节面板宽度（320–屏幕允许上限），支持平滑动画
    func setWidth(_ width: CGFloat, animated: Bool = false) {
        panelWidth = width
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        if !animated {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            panel.setFrame(panelRect(on: screen), display: true, animate: false)
            NSAnimationContext.endGrouping()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                panel.animator().setFrame(self.panelRect(on: screen), display: true)
            }
        }
        Log.write("面板宽度更新为 \(width) (animated: \(animated))")
    }


    // MARK: - 辅助

    private static let missingEditorHTML = """
    <html><body style="font:13px -apple-system;padding:24px;color:#A91E22">
    <b>找不到编辑器产物</b><br><br>
    请先在仓库根目录执行 <code>pnpm build</code>，再重新构建 App。
    </body></html>
    """
}

// MARK: - WKNavigationDelegate
//
// WebKit 的失败全是静默的（白屏、无日志），所以每个状态都打点。
// 另外顺带把 JS 侧的错误抛到原生日志里 —— file:// 下没法开 DevTools 调试。
extension PanelController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // 允许加载本地 file:// 静态资源
        if url.isFileURL {
            decisionHandler(.allow)
            return
        }
        // 拦截外部链接并在系统外部默认浏览器安全打开，杜绝篡改面板与消息通道暴露
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            Log.write("拦截外链并在外部浏览器安全打开：\(url.absoluteString)")
            return
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Log.write("Web 开始加载")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.write("Web 加载完成")
        let probe = """
        (() => {
          const app = document.getElementById('app');
          return {
            title: document.title,
            appChildren: app ? app.childElementCount : -1,
            hasPM: !!document.querySelector('.ProseMirror'),
            opacity: getComputedStyle(document.documentElement).getPropertyValue('--panel-opacity'),
            booted: window.__ifoloBooted || false,
            err: window.__ifoloBootError || null,
          };
        })()
        """
        webView.evaluateJavaScript(probe) { value, error in
            if let error {
                Log.write("Web 探针失败：\(error.localizedDescription)")
                return
            }
            Log.write("Web 探针：\(String(describing: value))")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("Web 加载失败：\(error)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Log.write("Web 准备阶段失败：\(error)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("Web 内容进程被终止（可能内存不足），重载")
        loadEditor(into: webView)
    }

    // MARK: - WKUIDelegate (支持系统输入对话框与确认弹窗)

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            completionHandler(input.stringValue)
        } else {
            completionHandler(nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
