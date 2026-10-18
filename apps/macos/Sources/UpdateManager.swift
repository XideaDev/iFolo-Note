import AppKit
import Sparkle

/// Sparkle 2 自动更新管理器
///
/// 职责：
/// 1. 封装 `SPUStandardUpdaterController`，提供标准原生 macOS 更新交互
/// 2. 实现 `SPUUpdaterDelegate` 与 `SPUStandardUserDriverDelegate`，监听全生命周期状态
/// 3. 支持「强制更新」(Critical Update) 与「非强制常规更新」的精准区分与行为控制
/// 4. 双向同步更新状态至 Web 偏好设置、关于弹窗及状态栏菜单
final class UpdateManager: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    static let shared = UpdateManager()

    private var updaterController: SPUStandardUpdaterController!

    /// 当前更新检测状态枚举
    enum UpdateState: String {
        case idle = "idle"
        case checking = "checking"
        case available = "available"
        case critical = "critical"
        case upToDate = "upToDate"
        case downloading = "downloading"
        case installing = "installing"
        case error = "error"
    }

    private(set) var currentState: UpdateState = .idle
    private(set) var latestItem: SUAppcastItem?

    private override init() {
        super.init()
    }

    /// 在 NSApplication 初始化完成时拉起 Sparkle 控制器
    func start() {
        guard updaterController == nil else { return }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        Log.write("Sparkle 2 自动更新模块已启动 (自动检查: \(automaticallyChecksForUpdates), 间隔: \(scheduledUpdateCheckInterval)s)")
    }

    // MARK: - 公共操作接口

    /// 用户主动检查更新 (前台触发，呈现标准 UI)
    @objc func checkForUpdates() {
        guard let controller = updaterController else {
            start()
            updaterController?.checkForUpdates(nil)
            return
        }

        currentState = .checking
        broadcastState(status: .checking)
        Log.write("用户主动触发检查更新")

        // 确保 App 处于激活态，弹窗置前
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// 后台静默检查更新
    func checkForUpdatesInBackground() {
        guard let controller = updaterController else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    /// 是否支持检查更新
    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    /// 是否开启自动检测
    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? true }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 是否开启自动下载
    var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? true }
        set { updaterController?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// 检查更新的时间间隔 (秒)
    var scheduledUpdateCheckInterval: TimeInterval {
        get { updaterController?.updater.updateCheckInterval ?? 86400 }
        set { updaterController?.updater.updateCheckInterval = newValue }
    }

    /// 上次检查时间
    var lastUpdateCheckDate: Date? {
        updaterController?.updater.lastUpdateCheckDate
    }

    /// 当前订阅的 Appcast URL
    var feedURLString: String? {
        updaterController?.updater.feedURL?.absoluteString
    }

    // MARK: - SPUUpdaterDelegate 核心生命周期监听

    /// 发现可用新版本
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        latestItem = item
        let isCritical = item.isCriticalUpdate
        currentState = isCritical ? .critical : .available

        Log.write("Sparkle 发现新版本: v\(item.displayVersionString) (Build \(item.versionString)), 强制更新: \(isCritical)")

        broadcastState(
            status: currentState,
            version: item.displayVersionString,
            isCritical: isCritical,
            releaseNotes: item.itemDescription
        )

        // 针对强制更新，强力提升前台优先级并警示
        if isCritical {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                Log.write("🚨 触发关键安全强制更新，已将更新窗口强制置前")
            }
        }
    }

    /// 当前已是最新版本
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        currentState = .upToDate
        Log.write("Sparkle 检查完成：当前已是最新版本")
        broadcastState(status: .upToDate)
    }

    /// 更新检查或下载异常中止
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        currentState = .error
        Log.write("Sparkle 更新中止或异常: \(error.localizedDescription)")
        broadcastState(status: .error, errorMessage: error.localizedDescription)
    }

    /// 即将开始下载更新包
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        currentState = .downloading
        Log.write("Sparkle 开始下载更新包: \(item.displayVersionString)")
        broadcastState(status: .downloading, version: item.displayVersionString)
    }

    /// 下载完成，即将解压提取
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        currentState = .installing
        Log.write("Sparkle 正在解压并校验更新包: \(item.displayVersionString)")
        broadcastState(status: .installing, version: item.displayVersionString)
    }

    /// 安装成功完成
    func updater(_ updater: SPUUpdater, didFinishInstallationWithError error: Error?) {
        if let error = error {
            currentState = .error
            Log.write("Sparkle 安装更新失败: \(error.localizedDescription)")
            broadcastState(status: .error, errorMessage: error.localizedDescription)
        } else {
            currentState = .idle
            Log.write("Sparkle 安装更新成功，即将重启新版本")
            broadcastState(status: .idle)
        }
    }

    // MARK: - SPUStandardUserDriverDelegate 用户界面驱动监听

    /// 即将呈现更新提示窗口
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Log.write("Sparkle 用户驱动即将展示更新窗口 (版本: \(update.displayVersionString))")
        // 若当前处于贴边隐藏面板态，确保更新窗口能够正常聚焦
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关闭更新提示窗口
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Log.write("Sparkle 更新窗口获取用户注意力")
    }

    // MARK: - Web 消息广播

    private func broadcastState(
        status: UpdateState,
        version: String? = nil,
        isCritical: Bool = false,
        releaseNotes: String? = nil,
        errorMessage: String? = nil
    ) {
        DispatchQueue.main.async {
            var payload: [String: Any] = [
                "status": status.rawValue,
                "isCritical": isCritical,
                "currentVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"
            ]
            if let version = version { payload["latestVersion"] = version }
            if let releaseNotes = releaseNotes { payload["releaseNotes"] = releaseNotes }
            if let errorMessage = errorMessage { payload["errorMessage"] = errorMessage }
            if let date = self.lastUpdateCheckDate {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                payload["lastChecked"] = formatter.string(from: date)
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            let js = "window.__ifoloUpdateStatusChanged && window.__ifoloUpdateStatusChanged(\(jsonString))"
            PanelController.shared.evaluate(js)
        }
    }
}
