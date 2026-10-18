import Foundation
import AppKit

/// 权限策略枚举
enum MCPPermissionStatus: String, Codable {
    case alwaysAllow = "always_allow"
    case askEveryTime = "ask_every_time"
    case disabled = "disabled"
}

/// 敏感数据类权限控制策略枚举
enum MCPSensitiveDataPolicy: String, Codable {
    case redact = "redact"                       // 自动脱敏访问（遮蔽私钥、Token、手机、证件等）
    case askEveryTime = "ask_every_time"         // 发现敏感数据时询问确认
    case block = "block"                         // 拦截访问（包含敏感数据直接拒绝）
    case allowPlaintext = "allow_plaintext"     // 允许明文访问（高风险）
}

/// 单个工具的配置元数据
struct MCPToolRule: Codable {
    var status: MCPPermissionStatus
    var updatedAt: Double
    var grantedBy: String
}

/// 权限整体持久化模型（向后兼容旧版 dlpRedaction 字段）
struct MCPPermissionConfig: Codable {
    var version: Int
    var globalEnabled: Bool
    var sensitiveDataPolicy: MCPSensitiveDataPolicy
    var tools: [String: MCPToolRule]

    enum CodingKeys: String, CodingKey {
        case version, globalEnabled, sensitiveDataPolicy, tools, dlpRedaction
    }

    init(version: Int, globalEnabled: Bool, sensitiveDataPolicy: MCPSensitiveDataPolicy, tools: [String: MCPToolRule]) {
        self.version = version
        self.globalEnabled = globalEnabled
        self.sensitiveDataPolicy = sensitiveDataPolicy
        self.tools = tools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        self.globalEnabled = (try? container.decode(Bool.self, forKey: .globalEnabled)) ?? true
        self.tools = (try? container.decode([String: MCPToolRule].self, forKey: .tools)) ?? [:]

        if let policy = try? container.decode(MCPSensitiveDataPolicy.self, forKey: .sensitiveDataPolicy) {
            self.sensitiveDataPolicy = policy
        } else if let dlp = try? container.decode(Bool.self, forKey: .dlpRedaction) {
            self.sensitiveDataPolicy = dlp ? .redact : .allowPlaintext
        } else {
            self.sensitiveDataPolicy = .redact
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(globalEnabled, forKey: .globalEnabled)
        try container.encode(sensitiveDataPolicy, forKey: .sensitiveDataPolicy)
        try container.encode(sensitiveDataPolicy == .redact, forKey: .dlpRedaction)
        try container.encode(tools, forKey: .tools)
    }
}
/// 审计日志条目
struct MCPAuditRecord: Codable {
    let id: String
    let timestamp: Double
    let tool: String
    let client: String
    let paramsSummary: String
    let decision: String   // "allowed", "blocked_disabled", "blocked_user_denied", "blocked_timeout"
    let redacted: Bool
}

/// MCP 权限与安全管理器
final class MCPPermissionManager {
    static let shared = MCPPermissionManager()

    private let root: URL
    private let configFile: URL
    private let auditFile: URL
    private let lock = NSLock()

    private var config: MCPPermissionConfig

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = base.appendingPathComponent("iFolo", isDirectory: true)
        configFile = root.appendingPathComponent("mcp-permissions.json")
        auditFile = root.appendingPathComponent("mcp-audit.log")

        // 默认配置
        let defaultTools: [String: MCPToolRule] = [
            "ifolo_list_notes": MCPToolRule(status: .alwaysAllow, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
            "ifolo_search_notes": MCPToolRule(status: .alwaysAllow, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
            "ifolo_read_note": MCPToolRule(status: .askEveryTime, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
            "ifolo_create_note": MCPToolRule(status: .askEveryTime, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
            "ifolo_append_note": MCPToolRule(status: .askEveryTime, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
        ]
        var loaded = MCPPermissionConfig(version: 1, globalEnabled: true, sensitiveDataPolicy: .redact, tools: defaultTools)

        if let data = try? Data(contentsOf: configFile),
           let decoded = try? JSONDecoder().decode(MCPPermissionConfig.self, from: data) {
            // 合并新增工具
            for (k, v) in defaultTools where decoded.tools[k] == nil {
                var copy = decoded
                copy.tools[k] = v
                loaded = copy
            }
            if loaded.tools.count == decoded.tools.count {
                loaded = decoded
            }
        }
        self.config = loaded
        saveConfigLocked()
    }

    // MARK: - 权限查询与设置

    func getOverview() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        var toolsMap: [String: [String: Any]] = [:]
        for (k, v) in config.tools {
            toolsMap[k] = [
                "status": v.status.rawValue,
                "updatedAt": v.updatedAt,
                "grantedBy": v.grantedBy
            ]
        }

        return [
            "globalEnabled": config.globalEnabled,
            "sensitiveDataPolicy": config.sensitiveDataPolicy.rawValue,
            "dlpRedaction": config.sensitiveDataPolicy == .redact,
            "tools": toolsMap
        ]
    }

    func setSensitiveDataPolicy(_ policy: MCPSensitiveDataPolicy) {
        lock.lock()
        config.sensitiveDataPolicy = policy
        saveConfigLocked()
        lock.unlock()
    }

    func setGlobalEnabled(_ enabled: Bool) {
        lock.lock()
        config.globalEnabled = enabled
        saveConfigLocked()
        lock.unlock()
    }

    func setDlpRedaction(_ enabled: Bool) {
        setSensitiveDataPolicy(enabled ? .redact : .allowPlaintext)
    }

    func setToolStatus(tool: String, status: MCPPermissionStatus) {
        lock.lock()
        config.tools[tool] = MCPToolRule(
            status: status,
            updatedAt: Date().timeIntervalSince1970,
            grantedBy: "user_settings"
        )
        saveConfigLocked()
        lock.unlock()
    }

    func resetPermissions() {
        lock.lock()
        config.sensitiveDataPolicy = .redact
        config.tools = [
            "ifolo_list_notes": MCPToolRule(status: .alwaysAllow, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
            "ifolo_search_notes": MCPToolRule(status: .alwaysAllow, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
            "ifolo_read_note": MCPToolRule(status: .askEveryTime, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
            "ifolo_create_note": MCPToolRule(status: .askEveryTime, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
            "ifolo_append_note": MCPToolRule(status: .askEveryTime, updatedAt: Date().timeIntervalSince1970, grantedBy: "default"),
        ]
        saveConfigLocked()
        lock.unlock()
    }

    var isGlobalEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return config.globalEnabled
    }

    var isDlpRedactionEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return config.sensitiveDataPolicy == .redact
    }

    var sensitiveDataPolicy: MCPSensitiveDataPolicy {
        lock.lock()
        defer { lock.unlock() }
        return config.sensitiveDataPolicy
    }

    // MARK: - 判定与弹窗授权

    enum AuthorizeDecision {
        case allow
        case blocked(reason: String)
    }

    func verifyOrPrompt(tool: String, arguments: [String: Any], clientName: String = "External Agent") -> AuthorizeDecision {
        lock.lock()
        guard config.globalEnabled else {
            lock.unlock()
            recordAudit(tool: tool, client: clientName, params: arguments, decision: "blocked_disabled", redacted: false)
            return .blocked(reason: "MCP 服务已在系统设置中全局禁用。")
        }

        let rule = config.tools[tool] ?? MCPToolRule(status: .askEveryTime, updatedAt: Date().timeIntervalSince1970, grantedBy: "first_use")
        let status = rule.status
        lock.unlock()

        switch status {
        case .disabled:
            recordAudit(tool: tool, client: clientName, params: arguments, decision: "blocked_disabled", redacted: false)
            return .blocked(reason: "工具 '\(tool)' 已被用户设置为禁用。")

        case .alwaysAllow:
            recordAudit(tool: tool, client: clientName, params: arguments, decision: "allowed", redacted: isDlpRedactionEnabled)
            return .allow

        case .askEveryTime:
            // 派发主线程弹窗请求用户显式授权
            let (allowed, remember) = promptUserOnMainThread(tool: tool, arguments: arguments, clientName: clientName)
            if allowed {
                if remember {
                    setToolStatus(tool: tool, status: .alwaysAllow)
                }
                recordAudit(tool: tool, client: clientName, params: arguments, decision: "allowed", redacted: isDlpRedactionEnabled)
                return .allow
            } else {
                recordAudit(tool: tool, client: clientName, params: arguments, decision: "blocked_user_denied", redacted: false)
                return .blocked(reason: "用户在系统授权弹窗中拒绝了本次调用。")
            }
        }
    }

    private func promptUserOnMainThread(tool: String, arguments: [String: Any], clientName: String) -> (allowed: Bool, remember: Bool) {
        var userAllowed = false
        var rememberChoice = false

        let group = DispatchGroup()
        group.enter()

        DispatchQueue.main.async {
            // 确保面板或主窗口可见
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "外部应用请求调用 MCP 工具"
            let summary = self.makeParamsSummary(tool: tool, arguments: arguments)
            alert.informativeText = "来源应用：\(clientName)\n请求工具：\(tool)\n操作摘要：\(summary)\n\n系统已启用敏感信息（私钥、Token、手机、邮箱）脱敏保护。"
            alert.alertStyle = .warning

            alert.addButton(withTitle: "允许调用")
            alert.addButton(withTitle: "拒绝")

            let checkbox = NSButton(checkboxWithTitle: "记住选择，今后对此工具始终允许", target: nil, action: nil)
            checkbox.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
            checkbox.state = .off
            alert.accessoryView = checkbox

            let response = alert.runModal()
            userAllowed = (response == .alertFirstButtonReturn)
            rememberChoice = (checkbox.state == .on)
            group.leave()
        }

        // 超时保护：最多等待 60 秒
        let waitResult = group.wait(timeout: .now() + 60.0)
        if waitResult == .timedOut {
            return (false, false)
        }
        return (userAllowed, rememberChoice)
    }

    // MARK: - 敏感数据识别与脱敏访问控制 (DLP)

    /// 识别文本中包含的敏感数据类型
    func detectSensitiveTypes(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var detected: [String] = []

        // 1. 私钥证书
        if text.range(of: "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----", options: .regularExpression) != nil {
            detected.append("私钥证书 (Private Key)")
        }

        // 2. 常见 API Token
        if text.range(of: "(sk-[a-zA-Z0-9_-]{20,})|(ghp_[a-zA-Z0-9]{30,})|(AKIA[0-9A-Z]{16})", options: .regularExpression) != nil {
            detected.append("API 密钥/Token")
        }

        // 3. 手机号码 (11位大陆号码及带+86)
        if text.range(of: "(?<!\\d)(?:\\+?86)?1[3-9]\\d{9}(?!\\d)", options: .regularExpression) != nil {
            detected.append("手机号码")
        }

        // 4. 身份证号 (18位)
        if text.range(of: "(?<!\\d)[1-9]\\d{5}(?:18|19|20)\\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}[\\dXx](?!\\d)", options: .regularExpression) != nil {
            detected.append("居民身份证号")
        }

        // 5. 电子邮箱
        if text.range(of: "[a-zA-Z0-9_.+-]{1,3}[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\\.[a-zA-Z0-9-.]+", options: .regularExpression) != nil {
            detected.append("电子邮箱")
        }

        return detected
    }

    /// 对敏感文本执行遮蔽脱敏
    func redactSensitiveInfo(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var redacted = text

        // 1. 私钥块脱敏
        let privateKeyRegex = "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"
        redacted = redacted.replacingOccurrences(of: privateKeyRegex, with: "[PROTECTED PRIVATE KEY]", options: .regularExpression)

        // 2. API Token 脱敏
        let tokenRegex = "(sk-[a-zA-Z0-9_-]{20,})|(ghp_[a-zA-Z0-9]{30,})|(AKIA[0-9A-Z]{16})"
        redacted = redacted.replacingOccurrences(of: tokenRegex, with: "[REDACTED_API_TOKEN]", options: .regularExpression)

        // 3. 手机号脱敏
        let phoneRegex = "(?<!\\d)(?:\\+?86)?1[3-9]\\d{9}(?!\\d)"
        if let regex = try? NSRegularExpression(pattern: phoneRegex) {
            let ns = redacted as NSString
            let matches = regex.matches(in: redacted, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                let full = ns.substring(with: m.range)
                let cleanDigits = full.filter { $0.isNumber }
                if cleanDigits.count == 11 {
                    let prefix = cleanDigits.prefix(3)
                    let suffix = cleanDigits.suffix(4)
                    let masked = "\(prefix)****\(suffix)"
                    redacted = (redacted as NSString).replacingCharacters(in: m.range, with: masked)
                }
            }
        }

        // 4. 身份证号脱敏
        let idCardRegex = "(?<!\\d)[1-9]\\d{5}(?:18|19|20)\\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}[\\dXx](?!\\d)"
        if let regex = try? NSRegularExpression(pattern: idCardRegex) {
            let ns = redacted as NSString
            let matches = regex.matches(in: redacted, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                let full = ns.substring(with: m.range)
                let prefix = full.prefix(4)
                let suffix = full.suffix(4)
                let masked = "\(prefix)**********\(suffix)"
                redacted = (redacted as NSString).replacingCharacters(in: m.range, with: masked)
            }
        }

        // 5. 邮箱脱敏
        let emailRegex = "([a-zA-Z0-9_.+-]{1,3})[a-zA-Z0-9_.+-]+@([a-zA-Z0-9-]+\\.[a-zA-Z0-9-.]+)"
        redacted = redacted.replacingOccurrences(of: emailRegex, with: "$1***@$2", options: .regularExpression)

        return redacted
    }

    /// 评估敏感数据策略与放行/拦截/脱敏
    func evaluateSensitiveData(
        content: String,
        tool: String,
        arguments: [String: Any],
        clientName: String = "External Agent"
    ) -> (allowed: Bool, processedContent: String, redacted: Bool, reason: String?) {
        lock.lock()
        let policy = config.sensitiveDataPolicy
        lock.unlock()

        let detected = detectSensitiveTypes(in: content)
        if detected.isEmpty {
            // 无敏感数据，直接放行明文
            return (true, content, false, nil)
        }

        let catSummary = detected.joined(separator: "、")

        switch policy {
        case .block:
            recordAudit(
                tool: tool,
                client: clientName,
                params: arguments,
                decision: "blocked_sensitive_data",
                redacted: false
            )
            return (false, "", false, "笔记包含敏感数据（\(catSummary)），已被当前【拦截访问】安全策略拦截。")

        case .redact:
            let safe = redactSensitiveInfo(content)
            recordAudit(
                tool: tool,
                client: clientName,
                params: arguments,
                decision: "allowed_redacted",
                redacted: true
            )
            return (true, safe, true, nil)

        case .allowPlaintext:
            recordAudit(
                tool: tool,
                client: clientName,
                params: arguments,
                decision: "allowed_sensitive_plaintext",
                redacted: false
            )
            return (true, content, false, nil)

        case .askEveryTime:
            let userAllowed = promptSensitiveDataUserOnMainThread(
                tool: tool,
                clientName: clientName,
                detectedCategories: detected
            )
            if userAllowed {
                recordAudit(
                    tool: tool,
                    client: clientName,
                    params: arguments,
                    decision: "allowed_sensitive_user_confirmed",
                    redacted: false
                )
                return (true, content, false, nil)
            } else {
                recordAudit(
                    tool: tool,
                    client: clientName,
                    params: arguments,
                    decision: "blocked_sensitive_user_denied",
                    redacted: false
                )
                return (false, "", false, "用户在敏感数据授权提示中拒绝了包含【\(catSummary)】的访问。")
            }
        }
    }

    private func promptSensitiveDataUserOnMainThread(tool: String, clientName: String, detectedCategories: [String]) -> Bool {
        var userAllowed = false
        let group = DispatchGroup()
        group.enter()

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "⚠️ 外部应用请求读取敏感数据"
            let cats = detectedCategories.joined(separator: "、")
            alert.informativeText = "来源应用：\(clientName)\n请求工具：\(tool)\n\n系统检测到该笔记包含以下敏感信息：\n• \(cats)\n\n由于当前安全策略配置为「发现敏感数据时询问」，请确认是否允许该外部 Agent 读取原始明文？"
            alert.alertStyle = .critical

            alert.addButton(withTitle: "拒绝访问")
            alert.addButton(withTitle: "允许本次明文读取")

            let response = alert.runModal()
            userAllowed = (response == .alertSecondButtonReturn)
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + 60.0)
        if waitResult == .timedOut {
            return false
        }
        return userAllowed
    }

    private func makeParamsSummary(tool: String, arguments: [String: Any]) -> String {
        switch tool {
        case "ifolo_read_note":
            let noteId = arguments["note_id"] as? String ?? ""
            return "读取笔记 (ID: \(noteId))"
        case "ifolo_search_notes":
            let query = arguments["query"] as? String ?? ""
            return "语义搜索关键词 \"\(query)\""
        case "ifolo_create_note":
            let title = arguments["title"] as? String ?? "无标题"
            return "创建新笔记 \"\(title)\""
        case "ifolo_append_note":
            let noteId = arguments["note_id"] as? String ?? ""
            return "向笔记 (ID: \(noteId)) 追加内容"
        default:
            return "获取笔记元信息或列表"
        }
    }

    // MARK: - 审计日志 (mcp-audit.log)

    func recordAudit(tool: String, client: String, params: [String: Any], decision: String, redacted: Bool) {
        let record = MCPAuditRecord(
            id: UUID().uuidString.prefix(8).lowercased(),
            timestamp: Date().timeIntervalSince1970,
            tool: tool,
            client: client,
            paramsSummary: makeParamsSummary(tool: tool, arguments: params),
            decision: decision,
            redacted: redacted
        )

        guard let encoded = try? JSONEncoder().encode(record),
              var line = String(data: encoded, encoding: .utf8) else { return }
        line.append("\n")

        guard let data = line.data(using: .utf8) else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            if let handle = try? FileHandle(forWritingTo: self.auditFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: self.auditFile, options: .atomic)
            }
            self.rotateAuditLogIfNeededLocked()
        }
    }

    func readRecentAuditRecords(limit: Int = 100) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        guard let text = try? String(contentsOf: auditFile, encoding: .utf8) else {
            return []
        }
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var records: [[String: Any]] = []

        for line in lines.reversed() {
            if records.count >= limit { break }
            if let d = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                records.append(obj)
            }
        }
        return records
    }

    func clearAuditLogs() {
        lock.lock()
        try? "".write(to: auditFile, atomically: true, encoding: .utf8)
        lock.unlock()
    }

    private func rotateAuditLogIfNeededLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: auditFile.path),
              let size = attrs[.size] as? Int, size > 2_000_000 else { return }
        let backup = auditFile.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: auditFile, to: backup)
    }

    private func saveConfigLocked() {
        if let encoded = try? JSONEncoder().encode(config) {
            try? encoded.write(to: configFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
