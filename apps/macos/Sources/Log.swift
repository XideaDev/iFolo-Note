import Foundation

/// 追加式日志。
///
/// 菜单栏 App 没有控制台，所有失败都是静默的 —— 上面那些「左键点了没反应」的症状，
/// 没有日志就只能靠猜。所以关键节点一律打点。
///
/// 日志位置：~/Library/Logs/iFolo.log
enum Log {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("iFolo.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let queue = DispatchQueue(label: "com.ifolo.log")

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 启动时调用一次，把上一次的日志归档，避免无限增长
    static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 512_000 else { return }
        let backup = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
