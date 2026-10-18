import WebKit
import AppKit

/// Web 内容与原生之间的消息桥。
///
/// 协议：JS 侧 `window.webkit.messageHandlers.ifolo.postMessage({ id, method, params })`，
/// 原生侧回 `window.__ifoloReceive(id, ok, payload)`。
/// `closePanel` 没有 id，是单向通知。
final class MessageBridge: NSObject, WKScriptMessageHandler {

    static let shared = MessageBridge()

    private override init() { super.init() }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            Log.write("收到无法解析的消息：\(message.body)")
            return
        }

        let id = body["id"] as? Int
        let params = body["params"] as? [String: Any] ?? [:]

        switch method {
        case "closePanel":
            PanelController.shared.hide()

        case "boot":
            let store = Store.shared
            store.seedIfEmpty()
            let notes = store.listNotes()
            var activeId = store.activeId()
            if activeId == nil || !notes.contains(where: { $0.id == activeId }) {
                activeId = notes.first?.id
            }
            let content = activeId.map { store.read(id: $0) } ?? ""
            let activeValue: Any = activeId ?? NSNull()
            reply(id, ok: true, payload: [
                "notes": notes.map { [
                    "id": $0.id,
                    "title": $0.title,
                    "updatedAt": $0.updatedAt,
                    "snippet": $0.snippet,
                    "tags": $0.tags ?? [],
                    "folderId": $0.folderId != nil ? ($0.folderId! as Any) : (NSNull() as Any),
                    "hasTodo": $0.hasTodo ?? false,
                    "isPinned": $0.isPinned ?? false,
                    "pinnedAt": $0.pinnedAt != nil ? ($0.pinnedAt! as Any) : (NSNull() as Any),
                    "isLocked": $0.isLocked ?? false,
                ] },
                "folders": store.listFolders().map { [
                    "id": $0.id,
                    "name": $0.name,
                    "isSystem": $0.isSystem ?? false,
                ] },
                "activeId": activeValue,
                "content": content,
                "panelWidth": Double(PanelController.shared.currentWidth),
                "panelOpacity": UserDefaults.standard.object(forKey: "ifolo.panelOpacity") as? Double ?? 0.82,
                "cardOpacity": UserDefaults.standard.object(forKey: "ifolo.cardOpacity") as? Double ?? 0.90,
                "statusBarIcon": UserDefaults.standard.string(forKey: "ifolo.statusBarIcon") ?? "notebook",
                "edgeHoverDelay": UserDefaults.standard.object(forKey: "ifolo.edgeHoverDelay") as? Double ?? 0.15,
                "isVaultUnlocked": NoteLockManager.shared.hasActiveSession,
            ])
            // 恢复透明度配置（面板透明度与卡片透明度独立无级调控）
            let savedOpacity = UserDefaults.standard.object(forKey: "ifolo.panelOpacity") as? Double ?? 0.82
            let savedCardOpacity = UserDefaults.standard.object(forKey: "ifolo.cardOpacity") as? Double ?? 0.90
            PanelController.shared.evaluate(
                "document.documentElement.style.setProperty('--panel-opacity', '\(savedOpacity)'); document.documentElement.style.setProperty('--card-opacity', '\(savedCardOpacity)');"
            )

        case "list":
            let notes = Store.shared.listNotes()
            reply(id, ok: true, payload: notes.map { [
                "id": $0.id,
                "title": $0.title,
                "updatedAt": $0.updatedAt,
                "snippet": $0.snippet,
                "tags": $0.tags ?? [],
                "folderId": $0.folderId != nil ? ($0.folderId! as Any) : (NSNull() as Any),
                "hasTodo": $0.hasTodo ?? false,
                "isPinned": $0.isPinned ?? false,
                "pinnedAt": $0.pinnedAt != nil ? ($0.pinnedAt! as Any) : (NSNull() as Any),
                "isLocked": $0.isLocked ?? false,
            ] })

        case "load":
            guard let noteId = params["id"] as? String else { return reply(id, ok: false, payload: "缺少 id") }
            Store.shared.setActive(noteId)
            reply(id, ok: true, payload: Store.shared.read(id: noteId))

        case "save":
            guard let noteId = params["id"] as? String,
                  let markdown = params["markdown"] as? String else {
                return reply(id, ok: false, payload: "缺少参数")
            }
            Store.shared.write(id: noteId, markdown: markdown)
            Store.shared.setActive(noteId)
            reply(id, ok: true, payload: NSNull())

        case "create":
            let folderId = params["folderId"] as? String
            let meta = Store.shared.create(folderId: folderId)
            reply(id, ok: true, payload: [
                "id": meta.id,
                "title": meta.title,
                "updatedAt": meta.updatedAt,
                "snippet": meta.snippet,
                "folderId": meta.folderId != nil ? (meta.folderId! as Any) : (NSNull() as Any),
                "hasTodo": meta.hasTodo ?? false,
                "isPinned": meta.isPinned ?? false,
                "pinnedAt": meta.pinnedAt != nil ? (meta.pinnedAt! as Any) : (NSNull() as Any),
                "isLocked": meta.isLocked ?? false,
            ])
        case "remove":
            guard let noteId = params["id"] as? String else { return reply(id, ok: false, payload: "缺少 id") }
            Store.shared.remove(id: noteId)
            reply(id, ok: true, payload: NSNull())

        case "rename":
            guard let noteId = params["id"] as? String,
                  let title = params["title"] as? String else {
                return reply(id, ok: false, payload: "缺少参数")
            }
            Store.shared.rename(id: noteId, title: title)
            reply(id, ok: true, payload: NSNull())

        case "setOpacity":
            if let value = params["value"] as? Double {
                let clamped = min(1.0, max(0.3, value))
                UserDefaults.standard.set(clamped, forKey: "ifolo.panelOpacity")
                PanelController.shared.evaluate(
                    "document.documentElement.style.setProperty('--panel-opacity', '\(clamped)')"
                )
            }
            reply(id, ok: true, payload: NSNull())

        case "setCardOpacity":
            if let value = params["value"] as? Double {
                let clamped = min(1.0, max(0.4, value))
                UserDefaults.standard.set(clamped, forKey: "ifolo.cardOpacity")
                PanelController.shared.evaluate(
                    "document.documentElement.style.setProperty('--card-opacity', '\(clamped)')"
                )
            }
            reply(id, ok: true, payload: NSNull())

        case "setWidth":
            if let value = params["width"] as? Double {
                PanelController.shared.setWidth(CGFloat(value))
            }
            reply(id, ok: true, payload: NSNull())

        case "search":
            let query = (params["query"] as? String) ?? ""
            SearchEngine.shared.search(query: query) { [weak self] results in
                DispatchQueue.main.async {
                    self?.reply(id, ok: true, payload: results.map { [
                        "id": $0.id,
                        "title": $0.title,
                        "snippet": $0.snippet,
                        "score": $0.score,
                        "matchedText": $0.matchedText,
                        "updatedAt": $0.updatedAt
                    ] })
                }
            }

        case "openFinder":
            NSWorkspace.shared.open(Store.shared.notesDirectoryURL)
            reply(id, ok: true, payload: NSNull())

        case "openTrash":
            let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSString(string: "~/.Trash").expandingTildeInPath)
            NSWorkspace.shared.open(trashURL)
            reply(id, ok: true, payload: NSNull())

        case "listTrash":
            let trashNotes = Store.shared.listTrash()
            reply(id, ok: true, payload: trashNotes.map { [
                "id": $0.id,
                "title": $0.title,
                "snippet": $0.snippet,
                "updatedAt": $0.updatedAt,
                "folderId": $0.folderId as Any,
                "hasTodo": $0.hasTodo as Any,
                "tags": $0.tags as Any,
                "isLocked": $0.isLocked ?? false,
            ] })

        case "restoreNote":
            guard let noteId = params["id"] as? String else { return reply(id, ok: false, payload: "缺少 id") }
            let ok = Store.shared.restoreNote(id: noteId)
            reply(id, ok: ok, payload: NSNull())

        case "purgeNote":
            guard let noteId = params["id"] as? String else { return reply(id, ok: false, payload: "缺少 id") }
            Store.shared.purgeNote(id: noteId)
            reply(id, ok: true, payload: NSNull())

        case "clearTrash":
            Store.shared.clearTrash()
            reply(id, ok: true, payload: NSNull())

        case "listFolders":
            let folders = Store.shared.listFolders()
            reply(id, ok: true, payload: folders.map { [
                "id": $0.id,
                "name": $0.name,
                "isSystem": $0.isSystem ?? false,
            ] })

        case "createFolder":
            guard let name = params["name"] as? String else { return reply(id, ok: false, payload: "缺少 name") }
            let folder = Store.shared.createFolder(name: name)
            reply(id, ok: true, payload: [
                "id": folder.id,
                "name": folder.name,
                "isSystem": folder.isSystem ?? false,
            ])

        case "renameFolder":
            guard let folderId = params["id"] as? String,
                  let name = params["name"] as? String else {
                return reply(id, ok: false, payload: "缺少参数")
            }
            Store.shared.renameFolder(id: folderId, name: name)
            reply(id, ok: true, payload: NSNull())

        case "deleteFolder":
            guard let folderId = params["id"] as? String else { return reply(id, ok: false, payload: "缺少 id") }
            Store.shared.deleteFolder(id: folderId)
            reply(id, ok: true, payload: NSNull())

        case "saveFoldersOrder":
            if let items = params["folders"] as? [[String: Any]] {
                let folders = items.compactMap { item -> FolderMeta? in
                    guard let fid = item["id"] as? String, let fname = item["name"] as? String else { return nil }
                    return FolderMeta(id: fid, name: fname, isSystem: item["isSystem"] as? Bool)
                }
                Store.shared.saveFoldersOrder(folders: folders)
            }
            reply(id, ok: true, payload: NSNull())

        case "setNoteFolder":
            guard let noteId = params["noteId"] as? String else { return reply(id, ok: false, payload: "缺少 noteId") }
            let folderId = params["folderId"] as? String
            Store.shared.setNoteFolder(noteId: noteId, folderId: folderId)
            reply(id, ok: true, payload: NSNull())

        case "setNotePinned":
            guard let noteId = params["noteId"] as? String,
                  let pinned = params["pinned"] as? Bool else {
                return reply(id, ok: false, payload: "缺少参数")
            }
            Store.shared.setNotePinned(noteId: noteId, pinned: pinned)
            reply(id, ok: true, payload: NSNull())
        case "setStatusBarIcon":
            if let iconName = params["name"] as? String {
                StatusItem.shared?.updateIcon(named: iconName)
            }
            reply(id, ok: true, payload: NSNull())
        case "setEdgeHover":
            if let enabled = params["enabled"] as? Bool {
                UserDefaults.standard.set(enabled, forKey: "ifolo.edgeHover")
                Log.write("设置边缘贴靠触发: \(enabled)")
            }
            reply(id, ok: true, payload: NSNull())
        case "setEdgeHoverDelay":
            if let delay = params["delay"] as? Double {
                let clamped = max(0.05, min(2.0, delay))
                UserDefaults.standard.set(clamped, forKey: "ifolo.edgeHoverDelay")
                EdgeTrigger.shared.updateDwell(clamped)
                Log.write("设置边缘悬停等待时长: \(clamped)s")
            }
            reply(id, ok: true, payload: NSNull())

        case "setAutoHide":
            if let enabled = params["enabled"] as? Bool {
                UserDefaults.standard.set(enabled, forKey: "ifolo.autoHide")
                Log.write("设置失焦自动隐藏: \(enabled)")
            }
            reply(id, ok: true, payload: NSNull())

        case "getMCPOverview":
            let overview = MCPPermissionManager.shared.getOverview()
            reply(id, ok: true, payload: overview)

        case "setMCPGlobalEnabled":
            if let enabled = params["enabled"] as? Bool {
                MCPPermissionManager.shared.setGlobalEnabled(enabled)
            }
            reply(id, ok: true, payload: NSNull())

        case "setMCPDlpRedaction":
            if let enabled = params["enabled"] as? Bool {
                MCPPermissionManager.shared.setDlpRedaction(enabled)
            }
            reply(id, ok: true, payload: NSNull())

        case "setMCPSensitiveDataPolicy":
            if let policyStr = params["policy"] as? String,
               let policy = MCPSensitiveDataPolicy(rawValue: policyStr) {
                MCPPermissionManager.shared.setSensitiveDataPolicy(policy)
            }
            reply(id, ok: true, payload: NSNull())

        case "setMCPToolStatus":
            if let tool = params["tool"] as? String,
               let statusStr = params["status"] as? String,
               let status = MCPPermissionStatus(rawValue: statusStr) {
                MCPPermissionManager.shared.setToolStatus(tool: tool, status: status)
            }
            reply(id, ok: true, payload: NSNull())

        case "resetMCPPermissions":
            MCPPermissionManager.shared.resetPermissions()
            reply(id, ok: true, payload: NSNull())

        case "getMCPAuditLogs":
            let limit = params["limit"] as? Int ?? 100
            let logs = MCPPermissionManager.shared.readRecentAuditRecords(limit: limit)
            reply(id, ok: true, payload: logs)

        case "clearMCPAuditLogs":
            MCPPermissionManager.shared.clearAuditLogs()
            reply(id, ok: true, payload: NSNull())

        case "setNoteLocked":
            guard let noteId = params["id"] as? String,
                  let locked = params["locked"] as? Bool else {
                return reply(id, ok: false, payload: "缺少参数")
            }
            Store.shared.setNoteLocked(id: noteId, locked: locked) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.reply(id, ok: true, payload: NSNull())
                    case .failure(let err):
                        self?.reply(id, ok: false, payload: err.localizedDescription)
                    }
                }
            }

        case "unlockNote":
            guard let noteId = params["id"] as? String else { return reply(id, ok: false, payload: "缺少 id") }
            Store.shared.unlockNote(id: noteId) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let markdown):
                        self?.reply(id, ok: true, payload: markdown)
                    case .failure(let err):
                        self?.reply(id, ok: false, payload: err.localizedDescription)
                    }
                }
            }

        case "lockVault":
            NoteLockManager.shared.lockSession()
            reply(id, ok: true, payload: NSNull())

        case "setVaultConfig":
            if let timeout = params["timeout"] as? Double {
                NoteLockManager.shared.setAutoLockTimeout(timeout)
                UserDefaults.standard.set(timeout, forKey: "ifolo.vaultTimeout")
            }
            if let touchId = params["touchId"] as? Bool {
                UserDefaults.standard.set(touchId, forKey: "ifolo.vaultTouchId")
            }
            reply(id, ok: true, payload: NSNull())

        case "getVaultConfig":
            let timeout = UserDefaults.standard.object(forKey: "ifolo.vaultTimeout") as? Double ?? NoteLockManager.shared.autoLockTimeout
            let touchId = UserDefaults.standard.object(forKey: "ifolo.vaultTouchId") as? Bool ?? true
            let hasPassword = UserDefaults.standard.string(forKey: "ifolo.vaultPassword") != nil
            reply(id, ok: true, payload: [
                "timeout": timeout,
                "touchId": touchId,
                "hasPassword": hasPassword,
                "isUnlocked": NoteLockManager.shared.hasActiveSession
            ])

        case "setVaultPassword":
            if let pwd = params["password"] as? String {
                let trimmed = pwd.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "ifolo.vaultPassword")
                    Log.write("MessageBridge: 已清除保险箱独立密码")
                } else {
                    UserDefaults.standard.set(trimmed, forKey: "ifolo.vaultPassword")
                    Log.write("MessageBridge: 已设置保险箱独立密码")
                }
            }
            reply(id, ok: true, payload: NSNull())
        default:
            Log.write("未知方法：\(method)")
            reply(id, ok: false, payload: "未知方法 \(method)")
        }
    }

    /// 回包给 JS。payload 用 JSON 序列化后再注入，避免手拼字符串的转义问题。
    private func reply(_ id: Int?, ok: Bool, payload: Any) {
        guard let id else { return }
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: [payload]),
           let text = String(data: data, encoding: .utf8) {
            // 剥掉外层 [...]，只取值
            var inner = String(text.dropFirst(1).dropLast(1))
            // 转义 JavaScript 行/段分隔符，杜绝注入 SyntaxError
            inner = inner.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            inner = inner.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            json = inner
        } else {
            json = "null"
        }
        PanelController.shared.evaluate("window.__ifoloReceive && window.__ifoloReceive(\(id), \(ok), \(json))")
    }
}
