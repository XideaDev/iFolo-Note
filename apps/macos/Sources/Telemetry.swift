import Foundation
import AppKit

/// OpenPanel 遥测统计模块 (方案 1: 原生异步代理通道)
/// 上报端点: https://stat.5956.net/api/track
/// CLIENT ID: 5dd8a354-9721-4998-aaaa-49186a79f9fd
final class Telemetry {

    static let shared = Telemetry()

    private let endpoint = "https://stat.5956.net/api/track"
    private let clientId = "5dd8a354-9721-4998-aaaa-49186a79f9fd"
    private let clientSecret = "sec_45e6780e710492424008"
    private let session: URLSession

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

    /// 用户是否开启了匿名遥测（默认开启，允许用户在设置中关闭）
    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "ifolo.telemetryEnabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ifolo.telemetryEnabled")
        }
    }

    /// 上报自定义事件
    func track(name: String, properties: [String: Any] = [:]) {
        guard isEnabled else { return }

        var finalProps: [String: Any] = [
            "platform": "macOS",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier,
        ]

        #if arch(arm64)
        finalProps["arch"] = "arm64"
        #elseif arch(x86_64)
        finalProps["arch"] = "x86_64"
        #endif

        // 合并业务属性（杜绝任何文本正文/敏感字段）
        for (k, v) in properties {
            if k.contains("content") || k.contains("text") || k.contains("password") || k.contains("markdown") {
                continue
            }
            finalProps[k] = v
        }

        let body: [String: Any] = [
            "type": "track",
            "payload": [
                "name": name,
                "profileId": profileId,
                "properties": finalProps,
            ]
        ]

        guard let url = URL(string: endpoint),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(clientId, forHTTPHeaderField: "openpanel-client-id")
        request.setValue(clientSecret, forHTTPHeaderField: "openpanel-client-secret")
        request.setValue("ifolo-macos", forHTTPHeaderField: "openpanel-sdk-name")
        request.setValue("1.0.0", forHTTPHeaderField: "openpanel-sdk-version")
        request.httpBody = jsonData

        // 后台异步静默发送，绝不阻塞主线程
        session.dataTask(with: request) { _, response, error in
            if let error = error {
                Log.write("Telemetry [\(name)] 上报失败: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                if http.statusCode < 300 {
                    Log.write("Telemetry [\(name)] 上报成功 (HTTP \(http.statusCode))")
                } else {
                    Log.write("Telemetry [\(name)] 响应异常 HTTP \(http.statusCode)")
                }
            }
        }.resume()
    }
}
