import Foundation
import AppKit

/// Umami 遥测统计模块 (原生异步代理通道)
/// 上报端点: https://stat.5956.net/api/send
/// WEBSITE ID: b3f35975-b11b-4c2d-94b7-5bf7d89081af
/// HOSTNAME: app.ifolo.macos
final class Telemetry {

    static let shared = Telemetry()

    private let endpoint = "https://stat.5956.net/api/send"
    private let websiteId = "b3f35975-b11b-4c2d-94b7-5bf7d89081af"
    private let hostname = "app.ifolo.macos"
    private let session: URLSession

    /// Umami 缓存 Token (用于维持连续会话与性能优化)
    private var umamiCacheToken: String? {
        get {
            UserDefaults.standard.string(forKey: "ifolo.umami.cache_token")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ifolo.umami.cache_token")
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// 设备匿名标识符（持久化在 UserDefaults，零关联用户个人身份）
    var profileId: String {
        let key = "ifolo.telemetry.profile_id"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let generated = "anon_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        UserDefaults.standard.set(String(generated), forKey: key)
        return String(generated)
    }

    /// 用户是否开启了匿名统计（默认开启，允许用户在设置中关闭）
    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "ifolo.telemetryEnabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ifolo.telemetryEnabled")
        }
    }

    /// 上报自定义事件至 Umami
    func track(name: String, properties: [String: Any] = [:]) {
        guard isEnabled else { return }

        var customData: [String: Any] = [
            "platform": "macOS",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]

        #if arch(arm64)
        customData["arch"] = "arm64"
        #elseif arch(x86_64)
        customData["arch"] = "x86_64"
        #endif

        // 合并业务属性（严格 DLP 防泄密：杜绝任何文本正文/敏感字段）
        for (k, v) in properties {
            let lk = k.lowercased()
            if lk.contains("content") || lk.contains("text") || lk.contains("password") || lk.contains("markdown") || lk.contains("secret") || lk.contains("token") {
                continue
            }
            customData[k] = v
        }

        // 获取屏幕分辨率
        let mainScreenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let screenStr = "\(Int(mainScreenSize.width))x\(Int(mainScreenSize.height))"
        let language = Locale.preferredLanguages.first ?? Locale.current.identifier

        let payload: [String: Any] = [
            "website": websiteId,
            "hostname": hostname,
            "screen": screenStr,
            "language": language,
            "url": "/",
            "title": "iFolo macOS Panel",
            "name": name,
            "data": customData,
        ]

        let body: [String: Any] = [
            "type": "event",
            "payload": payload,
        ]

        guard let url = URL(string: endpoint),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("iFolo/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0") (macOS)", forHTTPHeaderField: "User-Agent")

        if let cache = umamiCacheToken, !cache.isEmpty {
            request.setValue(cache, forHTTPHeaderField: "x-umami-cache")
        }

        request.httpBody = jsonData

        // 后台异步静默发送，绝不阻塞主线程
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                Log.write("Umami [\(name)] 上报失败: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                if http.statusCode < 300 {
                    Log.write("Umami [\(name)] 上报成功 (HTTP \(http.statusCode))")
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let cache = json["cache"] as? String {
                        self?.umamiCacheToken = cache
                    }
                } else {
                    Log.write("Umami [\(name)] 响应异常 HTTP \(http.statusCode)")
                }
            }
        }.resume()
    }
}
