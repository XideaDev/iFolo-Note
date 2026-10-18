import Foundation
import AppKit

// MARK: - MCP JSON-RPC 2.0 数据结构

struct MCPRequest: Codable {
    let jsonrpc: String
    let id: AnyCodable?
    let method: String
    let params: AnyCodable?
}

struct MCPResponse<T: Encodable>: Encodable {
    let jsonrpc: String = "2.0"
    let id: AnyCodable?
    let result: T?
    let error: MCPError?
}

struct MCPError: Codable, Error {
    let code: Int
    let message: String
    let data: AnyCodable?

    static func parseError(message: String = "Parse error") -> MCPError {
        MCPError(code: -32700, message: message, data: nil)
    }
    static func invalidRequest(message: String = "Invalid Request") -> MCPError {
        MCPError(code: -32600, message: message, data: nil)
    }
    static func methodNotFound(method: String) -> MCPError {
        MCPError(code: -32601, message: "Method not found: \(method)", data: nil)
    }
    static func invalidParams(message: String) -> MCPError {
        MCPError(code: -32602, message: message, data: nil)
    }
    static func internalError(message: String) -> MCPError {
        MCPError(code: -32603, message: message, data: nil)
    }
}

// MARK: - 动态 AnyCodable 支持

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self.value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot encode AnyCodable")
            throw EncodingError.invalidValue(self.value, context)
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var boolValue: Bool? { value as? Bool }
    var dictValue: [String: Any]? { value as? [String: Any] }
}

// MARK: - MCP 元数据模型

struct MCPServerInfo: Encodable {
    let name: String
    let version: String
}

struct MCPServerCapabilities: Encodable {
    let resources: [String: Bool]?
    let tools: [String: Bool]?
    let prompts: [String: Bool]?
}

struct MCPInitializeResult: Encodable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo
}

struct MCPToolDefinition: Encodable {
    let name: String
    let description: String
    let inputSchema: AnyCodable
}

struct MCPToolsListResult: Encodable {
    let tools: [MCPToolDefinition]
}

struct MCPResourceDefinition: Encodable {
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
}

struct MCPResourcesListResult: Encodable {
    let resources: [MCPResourceDefinition]
}

struct MCPResourceContent: Encodable {
    let uri: String
    let mimeType: String?
    let text: String?
}

struct MCPResourceReadResult: Encodable {
    let contents: [MCPResourceContent]
}

struct MCPToolCallContent: Encodable {
    let type: String = "text"
    let text: String
}

struct MCPToolCallResult: Encodable {
    let content: [MCPToolCallContent]
    let isError: Bool?
}

// MARK: - MCP Server 核心逻辑调度

final class MCPServer {
    static let shared = MCPServer()
    private let protocolVersion = "2024-11-05"

    private init() {}

    /// 处理单一 JSON-RPC 请求并返回序列化后的响应数据
    func handle(payload: Data) -> Data? {
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(MCPRequest.self, from: payload) else {
            let errResp = MCPResponse<String>(id: nil, result: nil, error: .parseError())
            return try? JSONEncoder().encode(errResp)
        }

        let id = request.id
        let responseData: Data?

        switch request.method {
        case "initialize":
            let result = MCPInitializeResult(
                protocolVersion: protocolVersion,
                capabilities: MCPServerCapabilities(
                    resources: ["subscribe": false, "listChanged": false],
                    tools: ["listChanged": false],
                    prompts: ["listChanged": false]
                ),
                serverInfo: MCPServerInfo(name: "ifolo-mcp", version: "0.3.0")
            )
            responseData = encodeResponse(id: id, result: result)

        case "notifications/initialized":
            // 客户端通知，无需响应
            return nil

        case "ping":
            responseData = encodeResponse(id: id, result: [String: String]())

        case "tools/list":
            guard MCPPermissionManager.shared.isGlobalEnabled else {
                let errResp = MCPResponse<String>(id: id, result: nil, error: .internalError(message: "MCP 本地服务已在 iFolo 偏好设置中全局停用。"))
                return try? JSONEncoder().encode(errResp)
            }
            let tools = registeredTools()
            responseData = encodeResponse(id: id, result: MCPToolsListResult(tools: tools))
        case "tools/call":
            responseData = handleToolCall(id: id, params: request.params)

        case "resources/list":
            let resources = registeredResources()
            responseData = encodeResponse(id: id, result: MCPResourcesListResult(resources: resources))

        case "resources/read":
            responseData = handleResourceRead(id: id, params: request.params)

        default:
            let errResp = MCPResponse<String>(id: id, result: nil, error: .methodNotFound(method: request.method))
            responseData = try? JSONEncoder().encode(errResp)
        }

        return responseData
    }

    private func encodeResponse<T: Encodable>(id: AnyCodable?, result: T) -> Data? {
        let resp = MCPResponse(id: id, result: result, error: nil)
        return try? JSONEncoder().encode(resp)
    }

    // MARK: - 工具定义与执行

    private func registeredTools() -> [MCPToolDefinition] {
        return [
            MCPToolDefinition(
                name: "ifolo_list_notes",
                description: "获取 iFolo 本地所有笔记的元数据清单（包含 ID、标题、修改时间、摘要、分类及置顶状态）。",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "返回条数限制，默认为 50"]
                    ]
                ])
            ),
            MCPToolDefinition(
                name: "ifolo_read_note",
                description: "根据笔记 ID 读取该篇笔记的完整 Markdown 正文内容。",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "string", "description": "笔记的唯一 UUID 标识"]
                    ],
                    "required": ["note_id"]
                ])
            ),
            MCPToolDefinition(
                name: "ifolo_search_notes",
                description: "在 iFolo 全部笔记库中执行基于语义向量和关键词的混合精准检索，返回最匹配的笔记列表及段落高亮。",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "搜索关键词或语义提问语句"],
                        "limit": ["type": "integer", "description": "最大返回匹配结果数，默认为 10"]
                    ],
                    "required": ["query"]
                ])
            ),
            MCPToolDefinition(
                name: "ifolo_create_note",
                description: "在 iFolo 中创建一篇新的 Markdown 笔记，原子性写入本地磁盘并立即构建语义索引。支持指定标题、正文及是否置顶。",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "笔记标题"],
                        "content": ["type": "string", "description": "笔记完整 Markdown 正文内容"],
                        "is_pinned": ["type": "boolean", "description": "是否置顶该笔记，默认为 false"]
                    ],
                    "required": ["content"]
                ])
            ),
            MCPToolDefinition(
                name: "ifolo_append_note",
                description: "向 iFolo 中已存在的某篇笔记末尾追加内容或任务清单，保留历史内容安全原子更新。",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "string", "description": "目标笔记的 UUID"],
                        "content_to_append": ["type": "string", "description": "需要追加到末尾的 Markdown 文本或待办列表"]
                    ],
                    "required": ["note_id", "content_to_append"]
                ])
            )
        ]
    }

    private func handleToolCall(id: AnyCodable?, params: AnyCodable?) -> Data? {
        guard let pDict = params?.dictValue,
              let toolName = pDict["name"] as? String else {
            let err = MCPError.invalidParams(message: "Missing 'name' in tools/call")
            return try? JSONEncoder().encode(MCPResponse<String>(id: id, result: nil, error: err))
        }

        let arguments = pDict["arguments"] as? [String: Any] ?? [:]

        // 权限校验与授权拦截（支持首次调用弹窗与禁用拦截）
        let authDecision = MCPPermissionManager.shared.verifyOrPrompt(tool: toolName, arguments: arguments, clientName: "MCP Stdio Client")
        switch authDecision {
        case .blocked(let reason):
            return encodeToolResult(id: id, text: "Error (Permission Denied): \(reason)", isError: true)
        case .allow:
            break
        }

        switch toolName {
        case "ifolo_list_notes":
            let limit = arguments["limit"] as? Int ?? 50
            let notes = Store.shared.listNotes()
            let sliced = Array(notes.prefix(limit))
            let formatted = sliced.map { n -> [String: Any] in
                var d: [String: Any] = [
                    "id": n.id,
                    "title": n.title,
                    "snippet": n.snippet,
                    "updatedAt": n.updatedAt,
                    "isPinned": n.isPinned ?? false
                ]
                if let fid = n.folderId { d["folderId"] = fid }
                if let ht = n.hasTodo { d["hasTodo"] = ht }
                if let tags = n.tags, !tags.isEmpty { d["tags"] = tags }
                return d
            }
            if let jsonStr = serializeJSON(formatted) {
                return encodeToolResult(id: id, text: jsonStr)
            }
            return encodeToolResult(id: id, text: "[]")

        case "ifolo_read_note":
            guard let noteId = sanitizeId(arguments["note_id"] as? String) else {
                return encodeToolResult(id: id, text: "Error: Invalid or missing note_id parameter", isError: true)
            }
            let content = Store.shared.read(id: noteId)
            if content.isEmpty {
                // 检查是否文件不存在
                let notes = Store.shared.listNotes()
                if !notes.contains(where: { $0.id == noteId }) {
                    return encodeToolResult(id: id, text: "Error: Note '\(noteId)' not found", isError: true)
                }
            }
            let sensitiveResult = MCPPermissionManager.shared.evaluateSensitiveData(
                content: content,
                tool: toolName,
                arguments: arguments,
                clientName: "MCP Stdio Client"
            )
            if !sensitiveResult.allowed {
                return encodeToolResult(id: id, text: "Error (Permission Denied): \(sensitiveResult.reason ?? "受敏感数据安全策略拦截")", isError: true)
            }
            return encodeToolResult(id: id, text: sensitiveResult.processedContent)

        case "ifolo_search_notes":
            guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return encodeToolResult(id: id, text: "Error: Missing search query", isError: true)
            }
            let limit = arguments["limit"] as? Int ?? 10
            let results = SearchEngine.shared.searchSync(query: query, limit: limit)
            let outList = results.map { r -> [String: Any] in
                return [
                    "id": r.id,
                    "title": r.title,
                    "score": r.score,
                    "snippet": MCPPermissionManager.shared.redactSensitiveInfo(r.snippet),
                    "matchedText": MCPPermissionManager.shared.redactSensitiveInfo(r.matchedText),
                    "updatedAt": r.updatedAt
                ]
            }
            let text = serializeJSON(outList) ?? "[]"
            return encodeToolResult(id: id, text: text)

        case "ifolo_create_note":
            let content = arguments["content"] as? String ?? ""
            let title = arguments["title"] as? String
            let isPinned = arguments["is_pinned"] as? Bool ?? false

            var finalContent = content
            if let t = title, !t.isEmpty, !content.hasPrefix("#") {
                finalContent = "# \(t)\n\n\(content)"
            }

            let meta = Store.shared.create()
            Store.shared.write(id: meta.id, markdown: finalContent)
            if isPinned {
                Store.shared.setNotePinned(noteId: meta.id, pinned: true)
            }
            SearchEngine.shared.indexNote(id: meta.id, content: finalContent)

            // 发送跨进程分布式广播，驱动正在运行的 iFolo GUI 面板实时热重载
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("iFoloDataChangedExternally"), object: nil, deliverImmediately: true)

            let resultDict = [
                "success": true,
                "note_id": meta.id,
                "message": "Note created successfully in local Markdown storage"
            ] as [String: Any]
            return encodeToolResult(id: id, text: serializeJSON(resultDict) ?? "{}")

        case "ifolo_append_note":
            guard let noteId = sanitizeId(arguments["note_id"] as? String),
                  let toAppend = arguments["content_to_append"] as? String else {
                return encodeToolResult(id: id, text: "Error: Missing note_id or content_to_append", isError: true)
            }
            let current = Store.shared.read(id: noteId)
            let notes = Store.shared.listNotes()
            guard notes.contains(where: { $0.id == noteId }) else {
                return encodeToolResult(id: id, text: "Error: Note '\(noteId)' not found", isError: true)
            }
            let separator = (current.isEmpty || current.hasSuffix("\n\n")) ? "" : (current.hasSuffix("\n") ? "\n" : "\n\n")
            let updated = current + separator + toAppend
            Store.shared.write(id: noteId, markdown: updated)
            SearchEngine.shared.indexNote(id: noteId, content: updated)

            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("iFoloDataChangedExternally"), object: nil, deliverImmediately: true)

            let res = ["success": true, "note_id": noteId, "message": "Content appended successfully"] as [String: Any]
            return encodeToolResult(id: id, text: serializeJSON(res) ?? "{}")

        default:
            let err = MCPError.methodNotFound(method: toolName)
            return try? JSONEncoder().encode(MCPResponse<String>(id: id, result: nil, error: err))
        }
    }

    private func encodeToolResult(id: AnyCodable?, text: String, isError: Bool = false) -> Data? {
        let result = MCPToolCallResult(content: [MCPToolCallContent(text: text)], isError: isError ? true : nil)
        return encodeResponse(id: id, result: result)
    }

    // MARK: - 资源系统

    private func registeredResources() -> [MCPResourceDefinition] {
        return [
            MCPResourceDefinition(
                uri: "ifolo://notes/recent",
                name: "最近编辑的笔记",
                description: "按修改时间倒序排列的最新笔记列表",
                mimeType: "application/json"
            ),
            MCPResourceDefinition(
                uri: "ifolo://folders",
                name: "文件夹分类树",
                description: "iFolo 中的所有自定义分类与系统文件夹",
                mimeType: "application/json"
            )
        ]
    }

    private func handleResourceRead(id: AnyCodable?, params: AnyCodable?) -> Data? {
        guard let pDict = params?.dictValue,
              let uri = pDict["uri"] as? String else {
            let err = MCPError.invalidParams(message: "Missing 'uri' in resources/read")
            return try? JSONEncoder().encode(MCPResponse<String>(id: id, result: nil, error: err))
        }

        if uri == "ifolo://notes/recent" {
            let notes = Store.shared.listNotes()
            let list = Array(notes.prefix(20)).map { ["id": $0.id, "title": $0.title, "snippet": $0.snippet] }
            let text = serializeJSON(list) ?? "[]"
            let res = MCPResourceReadResult(contents: [MCPResourceContent(uri: uri, mimeType: "application/json", text: text)])
            return encodeResponse(id: id, result: res)
        } else if uri == "ifolo://folders" {
            let folders = Store.shared.listFolders().map { ["id": $0.id, "name": $0.name, "isSystem": $0.isSystem ?? false] }
            let text = serializeJSON(folders) ?? "[]"
            let res = MCPResourceReadResult(contents: [MCPResourceContent(uri: uri, mimeType: "application/json", text: text)])
            return encodeResponse(id: id, result: res)
        } else if uri.hasPrefix("ifolo://notes/") {
            let noteId = uri.replacingOccurrences(of: "ifolo://notes/", with: "")
            if let validId = sanitizeId(noteId) {
                let content = Store.shared.read(id: validId)
                let safeContent = self.redactSensitiveInfo(content)
                let res = MCPResourceReadResult(contents: [MCPResourceContent(uri: uri, mimeType: "text/markdown", text: safeContent)])
                return encodeResponse(id: id, result: res)
            }
        }

        let err = MCPError.invalidParams(message: "Resource not found: \(uri)")
        return try? JSONEncoder().encode(MCPResponse<String>(id: id, result: nil, error: err))
    }

    // MARK: - 安全防护与辅助

    /// 严格校验并清理 noteId，杜绝路径穿越（例如 ../../.ssh/id_rsa）
    private func sanitizeId(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // 仅允许字母、数字、连字符、下划线
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        if s.contains("..") || s.contains("/") || s.contains("\\") { return nil }
        return s
    }

    private func serializeJSON(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - DLP 敏感数据防泄漏脱敏引擎
    /// 针对手机号、邮箱、身份证、API Token、私钥等核心凭证做掩码，防止外部 Agent 窥探用户隐私
    private func redactSensitiveInfo(_ text: String) -> String {
        return MCPPermissionManager.shared.redactSensitiveInfo(text)
    }

    // MARK: - Stdio 模式长轮询通信

    func startStdio() {
        // 预热向量检索引擎
        SearchEngine.shared.warmup(notes: Store.shared.listNotes())

        let inputHandle = FileHandle.standardInput
        let outputHandle = FileHandle.standardOutput

        var buffer = Data()
        let newlineData = "\n".data(using: .utf8)!

        inputHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF 外部进程已断开管道退出
                exit(0)
            }

            buffer.append(chunk)

            // 按行切分 JSON-RPC 消息
            while let range = buffer.range(of: newlineData) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)

                guard !lineData.isEmpty else { continue }
                if let responseData = self.handle(payload: lineData) {
                    outputHandle.write(responseData)
                    outputHandle.write(newlineData)
                }
            }
        }
    }
}
