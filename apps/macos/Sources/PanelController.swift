import AppKit
import WebKit

/// 面板控制器 —— 负责面板的创建、显隐、定位，以及 Web 内容与原生之间的消息桥。
final class PanelController: NSObject, WKUIDelegate {

    static let shared = PanelController()

    private var panel: PanelWindow?
    private var webView: WKWebView?
    private var outsideMonitor: Any?

    /// 计算当前允许的最大宽度（屏幕可见宽度的一半，至少 720pt）
    func maxAllowedWidth(on screen: NSScreen? = nil) -> CGFloat {
        let scr = screen ?? targetScreen()
        let half = floor(scr.visibleFrame.width / 2.0)
        return max(720, half)
    }

    /// 面板尺寸。宽度支持 320–(屏幕一半) 可调，默认 432
    var currentWidth: CGFloat {
        let val = UserDefaults.standard.double(forKey: "ifolo.panelWidth")
        let maxW = maxAllowedWidth()
        return val >= 320 && val <= maxW ? CGFloat(val) : 432
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

    private override init() { super.init() }

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

        // 面板已显示期间，完全移除全局鼠标移动监听，杜绝 IPC 干扰与掉帧
        EdgeTrigger.shared.stop()

        reposition(panel)
        // 必须用 orderFrontRegardless —— makeKeyAndOrderFront 在 App 非激活时会拒绝显示
        panel.orderFrontRegardless()
        takeKey()
        installOutsideMonitor()
        webView?.evaluateJavaScript("window.__ifoloRefreshNotes && window.__ifoloRefreshNotes(); window.__ifoloFocus && window.__ifoloFocus()")
        Log.write("面板显示 frame=\(panel.frame) visible=\(panel.isVisible) key=\(panel.isKeyWindow)")
    }

    func hide() {
        guard let panel else { return }
        removeOutsideMonitor()
        panel.orderOut(nil)
        // 面板收起后，重新启动屏幕边缘触发监听
        EdgeTrigger.shared.start()
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
        if let screenUnderMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
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

    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        // 全局监听不会收到发给本 App 的事件，所以面板内部的点击天然被忽略
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            // 判断是否启用失焦自动隐藏（默认 true，若用户关闭则不收起）
            let autoHide = UserDefaults.standard.object(forKey: "ifolo.autoHide") as? Bool ?? true
            if autoHide {
                self?.hide()
            }
        }
    }

    private func removeOutsideMonitor() {
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

    /// 调节面板宽度（320–屏幕一半）
    func setWidth(_ width: CGFloat) {
        panelWidth = width
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrame(panelRect(on: screen), display: true, animate: false)
        Log.write("面板宽度更新为 \(width)")
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
