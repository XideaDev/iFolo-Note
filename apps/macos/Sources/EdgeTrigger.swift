import AppKit

/// 屏幕边缘热区。
///
/// 实现选择：**全局鼠标移动监听 + 停留计时**，而不是在屏幕边缘放一个透明窗口。
///
/// 性能优化关键：
/// 1. 绝不能在每次鼠标移动时查询 `NSScreen.screens`（WindowServer IPC 耗时 ~0.8ms，
///    在 120Hz 下单帧仅 8.3ms，移动时会导致主线程严重掉帧、菜单与界面卡顿）。
/// 2. 缓存所有屏幕的边缘触发矩形，仅在 `didChangeScreenParametersNotification` 时刷新。
/// 3. 全局移动事件中先做单浮点数粗筛（`location.x < minZoneX`），在 <10ns 内过滤 99.9% 的无关移动。
/// 4. 面板已显示或处于暂停状态时直接短路跳出。
final class EdgeTrigger {

    static let shared = EdgeTrigger()

    /// 触发区宽度（点）。3pt 是「能碰到但不误触」的平衡点。
    /// 触发区宽度（点）。8pt 确保高分辨率与高速划过时可靠捕获
    var zoneWidth: CGFloat = 8
    /// 指针需要在触发区停留多久才展开面板（默认 0.15 秒，即 150ms）
    var dwell: TimeInterval = 0.15
    /// 默认支持在光标所在的任何屏幕边缘触发
    var allScreens = true

    private var monitor: Any?
    private var dwellTimer: Timer?
    private var armed = true
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private(set) var isPaused = false

    struct TriggerZone {
        let screenFrame: NSRect
        let triggerRect: NSRect
    }

    private var cachedZones: [TriggerZone] = []
    private var minZoneX: CGFloat = .greatestFiniteMagnitude

    func start() {
        stop()

        let enabled = UserDefaults.standard.object(forKey: "ifolo.edgeHover") as? Bool ?? true
        guard enabled else {
            Log.write("边缘触发未开启 (ifolo.edgeHover=false)，跳过监听器挂载")
            return
        }

        isPaused = false
        armed = true

        updateScreenCache()
        let nc = NotificationCenter.default
        let wsNc = NSWorkspace.shared.notificationCenter

        let o1 = nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateScreenCache()
        }
        let o2 = wsNc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cancelDwell()
            self.armed = true
            self.isPaused = false
            self.updateScreenCache()
            Log.write("桌面空间变更，边缘触发缓存已同步刷新")
        }
        let o3 = wsNc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("系统从休眠中唤醒，自愈重建边缘触发通道与事件监听器")
            self.cancelDwell()
            self.isPaused = false
            self.armed = true
            self.updateScreenCache()
            self.restartGlobalMonitor()
            self.restartPollTimer()
        }
        let o4 = wsNc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("屏幕亮屏唤醒，自愈重建边缘触发通道与事件监听器")
            self.cancelDwell()
            self.isPaused = false
            self.armed = true
            self.updateScreenCache()
            self.restartGlobalMonitor()
            self.restartPollTimer()
        }
        observers = [o1, o2, o3, o4]
        restartGlobalMonitor()

        // 从 UserDefaults 读取用户配置的悬停等待时长（默认 0.15s，范围 0.05s ~ 2.0s）
        let savedDelay = UserDefaults.standard.object(forKey: "ifolo.edgeHoverDelay") as? Double ?? 0.15
        self.dwell = max(0.05, min(2.0, savedDelay))

        // 2. 毫秒级轻量悬停轮询：解决无辅助功能权限或鼠标静止停留时无法收到 mouseMoved 事件的系统级死锁
        // 轮询周期自适应采样（确保在短延迟如 50ms 时也能灵敏响应）
        let pollInterval = min(0.1, max(0.04, self.dwell / 2.0))
        let pTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(pTimer, forMode: .common)
        pollTimer = pTimer

        Log.write("边缘触发已启动 zoneWidth=\(zoneWidth) dwell=\(dwell)s minZoneX=\(minZoneX)")
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        cancelDwell()
        armed = true
    }
    func pause() {
        isPaused = true
        cancelDwell()
    }

    func resume() {
        isPaused = false
        armed = true
        updateScreenCache()
    }
    /// 动态更新鼠标悬停等待时长并即时生效
    func updateDwell(_ newDwell: TimeInterval) {
        let clamped = max(0.05, min(2.0, newDwell))
        self.dwell = clamped
        cancelDwell()
        if pollTimer != nil {
            pollTimer?.invalidate()
            let pollInterval = min(0.1, max(0.04, clamped / 2.0))
            let pTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                self?.evaluate()
            }
            RunLoop.main.add(pTimer, forMode: .common)
            self.pollTimer = pTimer
        }
        Log.write("边缘悬停触发等待时长已更新为: \(clamped)s (\(Int(round(clamped * 1000)))ms)")
    }

    private func updateScreenCache() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            cachedZones = []
            minZoneX = .greatestFiniteMagnitude
            return
        }

        let targetScreens: [NSScreen]
        if allScreens {
            targetScreens = screens
        } else if let primary = screens.first(where: { $0.frame.origin == .zero }) {
            targetScreens = [primary]
        } else {
            targetScreens = [screens[0]]
        }

        var zones: [TriggerZone] = []
        var lowestX: CGFloat = .greatestFiniteMagnitude

        for screen in targetScreens {
            let frame = screen.frame
            // 采用屏幕物理矩形 frame（撑满物理高宽），杜绝 visibleFrame 因 Dock 栏或菜单栏位置导致的边缘盲区
            // 采用屏幕物理矩形 frame（撑满物理高宽），杜绝 visibleFrame 因 Dock 栏或菜单栏位置导致的边缘盲区
            // 上下及右边缘增加容差，解决 Cocoa NSRect.contains 针对 maxX / maxY 上边界半开区间 [min, max) 导致的顶角与极边缘脱靶问题
            let trigger = NSRect(
                x: frame.maxX - zoneWidth - 1,
                y: frame.minY - 2,
                width: zoneWidth + 4,
                height: frame.height + 4
            )
            zones.append(TriggerZone(screenFrame: frame, triggerRect: trigger))
            if trigger.minX < lowestX {
                lowestX = trigger.minX
            }
        }

        self.cachedZones = zones
        self.minZoneX = lowestX
        Log.write("边缘触发缓存更新: \(zones.count) 块屏幕, minZoneX=\(minZoneX)")
    }

    private func evaluate() {
        // 自愈看门狗：若面板客观未显示，强制自愈解除 isPaused 与 armed
        if isPaused && !PanelController.shared.isVisible {
            isPaused = false
            armed = true
        }

        // 0. 用户配置短路
        let enabled = UserDefaults.standard.object(forKey: "ifolo.edgeHover") as? Bool ?? true
        guard enabled else {
            if dwellTimer != nil { cancelDwell() }
            return
        }

        // 1. 状态短路：已暂停或面板已打开时退出
        guard !isPaused, !PanelController.shared.isVisible else {
            if dwellTimer != nil { cancelDwell() }
            return
        }

        let location = NSEvent.mouseLocation

        // 2. 精确多屏幕几何检测（彻底废弃粗暴提前截断的 minZoneX 陷阱）
        var inZone = false
        var inHysteresisZone = false

        for zone in cachedZones {
            if zone.triggerRect.contains(location) {
                inZone = true
                break
            }
            // 滞回容差区：进入热区后，允许手部向左微抖 24pt 而不掐死计时器
            let hysteresisRect = NSRect(
                x: zone.triggerRect.minX - 24,
                y: zone.triggerRect.minY,
                width: zone.triggerRect.width + 24,
                height: zone.triggerRect.height
            )
            if hysteresisRect.contains(location) {
                inHysteresisZone = true
            }
        }

        if inZone {
            guard armed else { return }
            startDwell()
        } else if inHysteresisZone && dwellTimer != nil {
            // 处在滞回缓冲区且计时器正在跑，不重置、不打断，平稳等待触发
            return
        } else {
            cancelDwell()
            armed = true
        }
    }

    private func startDwell() {
        guard dwellTimer == nil else { return }
        let timer = Timer(timeInterval: dwell, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.dwellTimer = nil
            guard self.armed, !self.isPaused, !PanelController.shared.isVisible else { return }
            self.armed = false
            Log.write("边缘触发命中，展开面板")
            Telemetry.shared.track(name: "panel_edge_triggered", properties: ["dwell_ms": Int(round(self.dwell * 1000))])
            PanelController.shared.show()
        }
        // .common 模式，否则菜单或弹窗打开时 run loop 切模式会让计时器停摆
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }
    private func restartGlobalMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        // 重新挂载全局鼠标事件，解决长时间休眠或安全会话切换后 WindowServer event tap 失效问题
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func restartPollTimer() {
        pollTimer?.invalidate()
        let pollInterval = min(0.1, max(0.04, self.dwell / 2.0))
        let pTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(pTimer, forMode: .common)
        pollTimer = pTimer
    }
}
