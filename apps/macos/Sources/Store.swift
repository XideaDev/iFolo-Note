import Foundation

/// 笔记元信息
/// 笔记元信息
struct NoteMeta: Codable {
    let id: String
    var title: String
    var updatedAt: Double
    var snippet: String
    var tags: [String]?
    var folderId: String?
    var hasTodo: Bool?
    var isPinned: Bool?
    var pinnedAt: Double?
    var isLocked: Bool?
}

/// 文件夹分类元信息
struct FolderMeta: Codable {
    let id: String
    var name: String
    var isSystem: Bool?
}

struct FolderStoreData: Codable {
    var folders: [FolderMeta]
    var noteFolders: [String: String] // [noteId: folderId]
    var pinnedNotes: [String: Double]? // [noteId: pinnedAt timestamp]
    var lockedNotes: [String: Bool]? // [noteId: isLocked]
}

/// 单篇笔记元数据缓存项（避免每次 listNotes 全盘读文本解析）
struct CachedNoteRecord: Codable {
    var mtime: Double
    var title: String
    var snippet: String
    var tags: [String]
    var hasTodo: Bool
    var isLocked: Bool?
}

/// 元数据持久化缓存
struct NoteMetaCacheData: Codable {
    var records: [String: CachedNoteRecord]
}

/// 本地 Markdown 存储
///
/// 目录：~/Library/Application Support/iFolo/notes/<id>.md
///
/// Markdown 是唯一真相源 —— 不是「导出格式之一」。App 被卸载、编辑器崩了，
/// 笔记仍然是普通文本文件，随手就能读。
final class Store {
    static let shared = Store()

    private let root: URL
    private let notesDir: URL
    private let assetsDir: URL
    private let trashDir: URL
    private let foldersFile: URL
    private let cacheFile: URL
    private var metaCache: [String: CachedNoteRecord] = [:]
    private let cacheLock = NSLock()
    private let defaults = UserDefaults.standard
    private let activeKey = "ifolo.activeNoteId"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = base.appendingPathComponent("iFolo", isDirectory: true)
        notesDir = root.appendingPathComponent("notes", isDirectory: true)
        assetsDir = root.appendingPathComponent("assets", isDirectory: true)
        trashDir = root.appendingPathComponent("trash", isDirectory: true)
        foldersFile = root.appendingPathComponent("folders.json")
        cacheFile = root.appendingPathComponent("meta-cache.json")
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        // 开启操作系统级完整文件加密保护属性（设备首次解锁前不可访问，防冷关机提取）
        try? FileManager.default.setAttributes([
            FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ], ofItemAtPath: notesDir.path)
        try? FileManager.default.setAttributes([
            FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ], ofItemAtPath: assetsDir.path)
        try? FileManager.default.setAttributes([
            FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ], ofItemAtPath: trashDir.path)
        loadMetaCache()
        Log.write("Store 就绪：\(notesDir.path)，附件目录：\(assetsDir.path)，缓存条目：\(metaCache.count)")
    }

    var notesDirectoryURL: URL { notesDir }

    // MARK: - 读取

    func listNotes() -> [NoteMeta] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        var result: [NoteMeta] = []
        let folderData = loadFolderData()
        let pinnedMap = folderData.pinnedNotes ?? [:]
        let lockedMap = folderData.lockedNotes ?? [:]
        var cacheDirty = false

        cacheLock.lock()
        for file in files where file.pathExtension == "md" {
            let id = file.deletingPathExtension().lastPathComponent
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let mtime = date?.timeIntervalSince1970 ?? 0
            let noteFolder = folderData.noteFolders[id]
            let isPinned = pinnedMap[id] != nil
            let pinnedAt = pinnedMap[id]
            let isLockedConfig = lockedMap[id] == true || noteFolder == "vault"

            let sessionActive = NoteLockManager.shared.hasActiveSession
            if let cached = metaCache[id], cached.mtime == mtime {
                let actualLocked = cached.isLocked ?? isLockedConfig
                result.append(NoteMeta(
                    id: id,
                    title: cached.title,
                    updatedAt: mtime,
                    snippet: (actualLocked && !sessionActive) ? "" : cached.snippet,
                    tags: (actualLocked && !sessionActive) ? [] : cached.tags,
                    folderId: noteFolder,
                    hasTodo: (actualLocked && !sessionActive) ? false : cached.hasTodo,
                    isPinned: isPinned,
                    pinnedAt: pinnedAt,
                    isLocked: actualLocked
                ))
            } else {
                let fileData = (try? Data(contentsOf: file)) ?? Data()
                let fileIsEncrypted = NoteLockManager.shared.isEncryptedData(fileData)
                let noteActuallyLocked = isLockedConfig || fileIsEncrypted

                let t: String
                let s: String
                let tags: [String]
                let hasTodo: Bool

                if noteActuallyLocked {
                    if let key = NoteLockManager.shared.currentSessionKey(),
                       let decrypted = try? NoteLockManager.shared.decrypt(envelopeData: fileData, with: key) {
                        t = title(from: decrypted)
                        s = extractSnippet(from: decrypted)
                        tags = Self.extractTags(from: decrypted)
                        hasTodo = Self.detectHasTodo(content: decrypted)
                    } else if let cached = metaCache[id], !cached.title.isEmpty {
                        t = cached.title
                        s = ""
                        tags = []
                        hasTodo = false
                    } else {
                        t = "锁定笔记"
                        s = ""
                        tags = []
                        hasTodo = false
                    }
                } else {
                    let content = String(data: fileData, encoding: .utf8) ?? ""
                    t = title(from: content)
                    s = extractSnippet(from: content)
                    tags = Self.extractTags(from: content)
                    hasTodo = Self.detectHasTodo(content: content)
                }

                metaCache[id] = CachedNoteRecord(mtime: mtime, title: t, snippet: s, tags: tags, hasTodo: hasTodo, isLocked: noteActuallyLocked)
                cacheDirty = true

                result.append(NoteMeta(
                    id: id,
                    title: t,
                    updatedAt: mtime,
                    snippet: s,
                    tags: tags,
                    folderId: noteFolder,
                    hasTodo: hasTodo,
                    isPinned: isPinned,
                    pinnedAt: pinnedAt,
                    isLocked: noteActuallyLocked
                ))
            }
        }

        // 清理已在磁盘被物理删除的遗留缓存键
        let existingIds = Set(files.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent })
        for cachedId in metaCache.keys where !existingIds.contains(cachedId) {
            metaCache.removeValue(forKey: cachedId)
            cacheDirty = true
        }

        if cacheDirty {
            saveMetaCacheLocked()
        }
        cacheLock.unlock()
        return result.sorted {
            let p0 = $0.isPinned ?? false
            let p1 = $1.isPinned ?? false
            if p0 != p1 {
                return p0 && !p1
            }
            if p0 && p1 {
                return ($0.pinnedAt ?? 0) > ($1.pinnedAt ?? 0)
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func read(id: String) -> String {
        let url = notesDir.appendingPathComponent("\(id).md")
        guard let data = try? Data(contentsOf: url) else { return "" }
        let folderData = loadFolderData()
        let isLocked = folderData.lockedNotes?[id] == true || folderData.noteFolders[id] == "vault" || NoteLockManager.shared.isEncryptedData(data)

        if isLocked {
            if let key = NoteLockManager.shared.currentSessionKey() {
                if NoteLockManager.shared.isEncryptedData(data) {
                    if let decrypted = try? NoteLockManager.shared.decrypt(envelopeData: data, with: key) {
                        return decrypted
                    }
                } else {
                    return String(data: data, encoding: .utf8) ?? ""
                }
            }
            return "<!-- IFOLO_LOCKED_NOTE -->"
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func activeId() -> String? {
        defaults.string(forKey: activeKey)
    }

    func setActive(_ id: String) {
        defaults.set(id, forKey: activeKey)
    }

    // MARK: - 写入

    @discardableResult
    func create(folderId: String? = nil) -> NoteMeta {
        let id = UUID().uuidString.lowercased()
        let isVault = folderId == "vault"
        var data = loadFolderData()
        if let folderId = folderId, !folderId.isEmpty, folderId != "all" {
            data.noteFolders[id] = folderId
        }
        if isVault {
            if data.lockedNotes == nil { data.lockedNotes = [:] }
            data.lockedNotes?[id] = true
        }
        saveFolderData(data)

        let initialTitle = isVault ? "未命名加密笔记" : "无标题"
        let initialContent = isVault ? "# 未命名加密笔记\n\n" : ""
        let meta = NoteMeta(
            id: id,
            title: initialTitle,
            updatedAt: Date().timeIntervalSince1970,
            snippet: "",
            tags: [],
            folderId: isVault ? "vault" : folderId,
            hasTodo: false,
            isPinned: false,
            pinnedAt: nil,
            isLocked: isVault
        )

        if isVault {
            if NoteLockManager.shared.currentSessionKey() != nil {
                write(id: id, markdown: initialContent)
            } else {
                let url = notesDir.appendingPathComponent("\(id).md")
                try? initialContent.write(to: url, atomically: true, encoding: .utf8)
                cacheLock.lock()
                metaCache[id] = CachedNoteRecord(mtime: Date().timeIntervalSince1970, title: initialTitle, snippet: "", tags: [], hasTodo: false, isLocked: true)
                saveMetaCacheLocked()
                cacheLock.unlock()
            }
        } else {
            write(id: id, markdown: initialContent)
        }

        setActive(id)
        Log.write("新建笔记 \(id) (分类: \(folderId ?? "nil"), 加密: \(isVault))")
        return meta
    }

    func write(id: String, markdown: String) {
        let url = notesDir.appendingPathComponent("\(id).md")
        let folderData = loadFolderData()
        let isLocked = folderData.lockedNotes?[id] == true || folderData.noteFolders[id] == "vault"

        do {
            if isLocked {
                if let key = NoteLockManager.shared.currentSessionKey() {
                    let envelope = try NoteLockManager.shared.encrypt(markdown: markdown, with: key)
                    try envelope.write(to: url, options: .atomic)
                } else {
                    if let existingData = try? Data(contentsOf: url), NoteLockManager.shared.isEncryptedData(existingData) {
                        Log.write("跳过未鉴权的写入以保护密文 \(id)")
                        return
                    }
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                }
            } else {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            }

            try? FileManager.default.setAttributes([
                FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ], ofItemAtPath: url.path)

            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            let t = title(from: markdown)
            let s = isLocked ? "" : extractSnippet(from: markdown)
            let tags = isLocked ? [] : Self.extractTags(from: markdown)
            let hasTodo = isLocked ? false : Self.detectHasTodo(content: markdown)

            cacheLock.lock()
            metaCache[id] = CachedNoteRecord(mtime: mtime, title: t, snippet: s, tags: tags, hasTodo: hasTodo, isLocked: isLocked)
            saveMetaCacheLocked()
            cacheLock.unlock()

            if isLocked {
                SearchEngine.shared.removeNote(id: id)
            } else {
                SearchEngine.shared.indexNote(id: id, content: markdown)
            }
        } catch {
            Log.write("写入失败 \(id)：\(error)")
        }
    }

    func setNoteLocked(id: String, locked: Bool, completion: @escaping (Result<Void, NoteLockError>) -> Void) {
        var data = loadFolderData()
        if data.lockedNotes == nil { data.lockedNotes = [:] }
        let currentContent = read(id: id)
        let url = notesDir.appendingPathComponent("\(id).md")

        if locked {
            NoteLockManager.shared.authenticate(reason: "请验证身份以将笔记加锁并移入保险箱") { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let key):
                    do {
                        let text = (currentContent == "<!-- IFOLO_LOCKED_NOTE -->") ? "" : currentContent
                        let envelope = try NoteLockManager.shared.encrypt(markdown: text, with: key)
                        try envelope.write(to: url, options: .atomic)

                        data.lockedNotes?[id] = true
                        data.noteFolders[id] = "vault"
                        self.saveFolderData(data)

                        self.cacheLock.lock()
                        let t = self.title(from: text)
                        self.metaCache[id] = CachedNoteRecord(mtime: Date().timeIntervalSince1970, title: t.isEmpty ? "锁定笔记" : t, snippet: "", tags: [], hasTodo: false, isLocked: true)
                        self.saveMetaCacheLocked()
                        self.cacheLock.unlock()

                        SearchEngine.shared.removeNote(id: id)
                        Log.write("笔记 \(id) 已加锁并移入保险箱")
                        completion(.success(()))
                    } catch {
                        completion(.failure(.decryptionFailed))
                    }
                case .failure(let err):
                    completion(.failure(err))
                }
            }
        } else {
            NoteLockManager.shared.authenticate(reason: "请验证身份以解除笔记锁定并移出保险箱") { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let key):
                    do {
                        let envelopeData = (try? Data(contentsOf: url)) ?? Data()
                        let plaintext: String
                        if NoteLockManager.shared.isEncryptedData(envelopeData) {
                            plaintext = try NoteLockManager.shared.decrypt(envelopeData: envelopeData, with: key)
                        } else {
                            plaintext = currentContent
                        }
                        try plaintext.write(to: url, atomically: true, encoding: .utf8)

                        data.lockedNotes?.removeValue(forKey: id)
                        if data.noteFolders[id] == "vault" {
                            data.noteFolders.removeValue(forKey: id)
                        }
                        self.saveFolderData(data)

                        let mtime = Date().timeIntervalSince1970
                        let t = self.title(from: plaintext)
                        let s = self.extractSnippet(from: plaintext)
                        let tags = Self.extractTags(from: plaintext)
                        let hasTodo = Self.detectHasTodo(content: plaintext)

                        self.cacheLock.lock()
                        self.metaCache[id] = CachedNoteRecord(mtime: mtime, title: t, snippet: s, tags: tags, hasTodo: hasTodo, isLocked: false)
                        self.saveMetaCacheLocked()
                        self.cacheLock.unlock()

                        SearchEngine.shared.indexNote(id: id, content: plaintext)
                        Log.write("笔记 \(id) 已解除锁定并移出保险箱")
                        completion(.success(()))
                    } catch {
                        completion(.failure(.decryptionFailed))
                    }
                case .failure(let err):
                    completion(.failure(err))
                }
            }
        }
    }

    func unlockNote(id: String, password: String? = nil, completion: @escaping (Result<String, NoteLockError>) -> Void) {
        let url = notesDir.appendingPathComponent("\(id).md")
        guard let data = try? Data(contentsOf: url) else {
            completion(.success(""))
            return
        }

        let folderData = loadFolderData()
        let isLocked = folderData.lockedNotes?[id] == true || folderData.noteFolders[id] == "vault" || NoteLockManager.shared.isEncryptedData(data)
        if !isLocked {
            completion(.success(String(data: data, encoding: .utf8) ?? ""))
            return
        }
        // 1. 若前端传入了独立密码，直接用密码验证并解密，完全免除 Touch ID 系统弹窗
        if let pwd = password, !pwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch NoteLockManager.shared.unlockWithPassword(pwd) {
            case .success(let key):
                do {
                    let decrypted = try NoteLockManager.shared.decrypt(envelopeData: data, with: key)
                    completion(.success(decrypted))
                    return
                } catch {
                    completion(.failure(.decryptionFailed))
                    return
                }
            case .failure(let err):
                completion(.failure(err))
                return
            }
        }

        // 2. 若当前会话已有有效密钥（在免密时限内），直接静默解密
        if let key = NoteLockManager.shared.currentSessionKey() {
            do {
                let decrypted = try NoteLockManager.shared.decrypt(envelopeData: data, with: key)
                completion(.success(decrypted))
                return
            } catch {}
        }

        // 3. 否则唤起硬件 Touch ID 验证
        NoteLockManager.shared.authenticate(reason: "解锁此受保护的私密笔记") { result in
            switch result {
            case .success(let key):
                do {
                    let decrypted = try NoteLockManager.shared.decrypt(envelopeData: data, with: key)
                    completion(.success(decrypted))
                } catch {
                    completion(.failure(.decryptionFailed))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    private func loadMetaCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let data = try? Data(contentsOf: cacheFile),
           let decoded = try? JSONDecoder().decode(NoteMetaCacheData.self, from: data) {
            metaCache = decoded.records
        }
    }

    private func saveMetaCacheLocked() {
        let dataObj = NoteMetaCacheData(records: metaCache)
        if let encoded = try? JSONEncoder().encode(dataObj) {
            try? encoded.write(to: cacheFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func remove(id: String) {
        let noteURL = notesDir.appendingPathComponent("\(id).md")
        let trashURL = trashDir.appendingPathComponent("\(id).md")

        // 移入应用专属回收站，支持在应用内独立回收站页面查看与一键恢复
        if FileManager.default.fileExists(atPath: noteURL.path) {
            try? FileManager.default.removeItem(at: trashURL)
            try? FileManager.default.moveItem(at: noteURL, to: trashURL)
        }

        SearchEngine.shared.removeNote(id: id)
        var data = loadFolderData()
        cacheLock.lock()
        if metaCache.removeValue(forKey: id) != nil {
            saveMetaCacheLocked()
        }
        cacheLock.unlock()
        if data.pinnedNotes?.removeValue(forKey: id) != nil {
            saveFolderData(data)
        }
        Log.write("笔记 \(id) 已移入应用回收站")
    }

    // MARK: - 回收站管理

    func listTrash() -> [NoteMeta] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        var result: [NoteMeta] = []
        let folderData = loadFolderData()
        let sessionActive = NoteLockManager.shared.hasActiveSession

        for file in files where file.pathExtension == "md" {
            let id = file.deletingPathExtension().lastPathComponent
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let mtime = date?.timeIntervalSince1970 ?? 0
            let noteFolder = folderData.noteFolders[id]
            let fileData = (try? Data(contentsOf: file)) ?? Data()
            let isEncrypted = NoteLockManager.shared.isEncryptedData(fileData)
            let isLocked = folderData.lockedNotes?[id] == true || noteFolder == "vault" || isEncrypted

            let t: String
            let s: String
            let tags: [String]
            let hasTodo: Bool

            if isEncrypted {
                if sessionActive, let key = NoteLockManager.shared.currentSessionKey(),
                   let decrypted = try? NoteLockManager.shared.decrypt(envelopeData: fileData, with: key) {
                    t = title(from: decrypted)
                    s = extractSnippet(from: decrypted)
                    tags = Self.extractTags(from: decrypted)
                    hasTodo = Self.detectHasTodo(content: decrypted)
                } else {
                    t = "锁定笔记"
                    s = "受保护的私密笔记（验证身份后查看）"
                    tags = []
                    hasTodo = false
                }
            } else if let content = String(data: fileData, encoding: .utf8) {
                t = title(from: content)
                s = extractSnippet(from: content)
                tags = Self.extractTags(from: content)
                hasTodo = Self.detectHasTodo(content: content)
            } else {
                t = "未命名笔记"
                s = ""
                tags = []
                hasTodo = false
            }

            result.append(NoteMeta(
                id: id,
                title: t,
                updatedAt: mtime,
                snippet: s,
                tags: tags,
                folderId: noteFolder,
                hasTodo: hasTodo,
                isPinned: false,
                pinnedAt: nil,
                isLocked: isLocked
            ))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func restoreNote(id: String) -> Bool {
        let trashURL = trashDir.appendingPathComponent("\(id).md")
        let noteURL = notesDir.appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return false }

        try? FileManager.default.removeItem(at: noteURL)
        do {
            try FileManager.default.moveItem(at: trashURL, to: noteURL)
            let fileData = (try? Data(contentsOf: noteURL)) ?? Data()
            if NoteLockManager.shared.isEncryptedData(fileData) {
                var data = loadFolderData()
                if data.lockedNotes == nil { data.lockedNotes = [:] }
                data.lockedNotes?[id] = true
                if data.noteFolders[id] == nil {
                    data.noteFolders[id] = "vault"
                }
                saveFolderData(data)

                let t: String
                if let key = NoteLockManager.shared.currentSessionKey(),
                   let decrypted = try? NoteLockManager.shared.decrypt(envelopeData: fileData, with: key) {
                    t = title(from: decrypted)
                } else {
                    t = "锁定笔记"
                }
                cacheLock.lock()
                metaCache[id] = CachedNoteRecord(mtime: Date().timeIntervalSince1970, title: t, snippet: "", tags: [], hasTodo: false, isLocked: true)
                saveMetaCacheLocked()
                cacheLock.unlock()
            } else if let content = String(data: fileData, encoding: .utf8) {
                SearchEngine.shared.indexNote(id: id, content: content)
            }
            Log.write("从回收站恢复笔记 \(id)")
            return true
        } catch {
            Log.write("恢复笔记 \(id) 失败: \(error)")
            return false
        }
    }

    func purgeNote(id: String) {
        let trashURL = trashDir.appendingPathComponent("\(id).md")
        try? FileManager.default.removeItem(at: trashURL)
        var data = loadFolderData()
        data.noteFolders.removeValue(forKey: id)
        data.lockedNotes?.removeValue(forKey: id)
        saveFolderData(data)
        Log.write("彻底清除回收站笔记 \(id)")
    }

    func clearTrash() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "md" {
                try? fm.removeItem(at: file)
            }
        }
        Log.write("已清空应用回收站")
    }

    func setNotePinned(noteId: String, pinned: Bool) {
        var data = loadFolderData()
        if data.pinnedNotes == nil {
            data.pinnedNotes = [:]
        }
        if pinned {
            data.pinnedNotes?[noteId] = Date().timeIntervalSince1970
        } else {
            data.pinnedNotes?.removeValue(forKey: noteId)
        }
        saveFolderData(data)
        Log.write("设置笔记置顶 \(noteId): \(pinned)")
    }

    // MARK: - 文件夹分类管理

    private var noteFoldersMap: [String: String] {
        loadFolderData().noteFolders
    }

    private func loadFolderData() -> FolderStoreData {
        let systemFolders: [FolderMeta] = [
            FolderMeta(id: "all", name: "全部", isSystem: true),
            FolderMeta(id: "vault", name: "保险箱", isSystem: true),
            FolderMeta(id: "todo", name: "Todos", isSystem: true),
        ]
        if let data = try? Data(contentsOf: foldersFile),
           var decoded = try? JSONDecoder().decode(FolderStoreData.self, from: data) {
            decoded.folders.removeAll(where: { $0.id == "note" })
            for i in 0..<decoded.folders.count {
                if decoded.folders[i].id == "todo" {
                    decoded.folders[i].name = "Todos"
                }
            }
            // 强制保证前三位系统分类固定排序：全部 -> 保险箱 -> Todos
            let custom = decoded.folders.filter { $0.id != "vault" && $0.id != "all" && $0.id != "todo" }
            decoded.folders = systemFolders + custom
            saveFolderData(decoded)
            return decoded
        }
        let initialData = FolderStoreData(folders: systemFolders, noteFolders: [:], pinnedNotes: [:], lockedNotes: [:])
        saveFolderData(initialData)
        return initialData
    }

    private func saveFolderData(_ data: FolderStoreData) {
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: foldersFile, options: .atomic)
        }
    }

    func listFolders() -> [FolderMeta] {
        return loadFolderData().folders
    }

    func saveFoldersOrder(folders: [FolderMeta]) {
        var data = loadFolderData()
        data.folders = folders
        saveFolderData(data)
        Log.write("已保存文件夹排序 (共 \(folders.count) 个分类)")
    }

    func createFolder(name: String) -> FolderMeta {
        var data = loadFolderData()
        let id = "folder-" + UUID().uuidString.lowercased().prefix(8)
        let folder = FolderMeta(id: id, name: name, isSystem: false)
        data.folders.append(folder)
        saveFolderData(data)
        Log.write("新建文件夹分类: \(name) (\(id))")
        return folder
    }

    func renameFolder(id: String, name: String) {
        var data = loadFolderData()
        if let idx = data.folders.firstIndex(where: { $0.id == id }) {
            data.folders[idx].name = name
            saveFolderData(data)
            Log.write("重命名文件夹分类: \(id) -> \(name)")
        }
    }

    func deleteFolder(id: String) {
        if id == "all" || id == "todo" || id == "vault" { return }
        var data = loadFolderData()
        data.folders.removeAll(where: { $0.id == id })
        // 清理属于该分类的笔记关联
        data.noteFolders = data.noteFolders.filter { $0.value != id }
        saveFolderData(data)
        Log.write("删除文件夹分类: \(id)")
    }
    func setNoteFolder(noteId: String, folderId: String?) {
        var data = loadFolderData()
        if let folderId = folderId, !folderId.isEmpty, folderId != "all" {
            data.noteFolders[noteId] = folderId
        } else {
            data.noteFolders.removeValue(forKey: noteId)
        }
        saveFolderData(data)
        Log.write("设置笔记 \(noteId) 所属文件夹: \(folderId ?? "nil")")
    }

    func rename(id: String, title: String) {
        let current = read(id: id)
        var lines = current.components(separatedBy: "\n")
        let heading = "# \(title)"
        if let first = lines.first, first.hasPrefix("#") {
            lines[0] = heading
        } else {
            lines.insert(heading, at: 0)
            lines.insert("", at: 1)
        }
        write(id: id, markdown: lines.joined(separator: "\n"))
    }

    /// 首次启动时种一条欢迎笔记，避免用户打开面板看到一片空白
    func seedIfEmpty() {
        guard listNotes().isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        let welcome = """
        # 欢迎使用 iFolo

        把指针移到屏幕右边缘，或按 ⌥⌘N 呼出面板。

        - [ ] 试试输入 `/` 唤出命令
        - [inProgress] 悬停段落左侧能看到手柄
        - [ ] 选中文字试试富文本工具栏
        """
        write(id: id, markdown: welcome)
        setActive(id)
        Log.write("已种入欢迎笔记 \(id)")
    }

    // MARK: - 辅助

    /// 明确判定整篇笔记内容是否「含有待办」：
    /// 1. 标准与扩展 Markdown 复选框/任务项：- [ ], - [x], - [inProgress], - [inReview], - [backlog], - [cancelled] 等；
    /// 2. HTML 任务或复选框标记；
    /// 3. 行首或标题显式待办标记（如【待办】、TODO:、待办事项、任务清单等）。
    static func detectHasTodo(content: String) -> Bool {
        if content.isEmpty { return false }
        // 1. Markdown 任务项正则
        let taskPattern = "(?mi)^\\s*(?:[-*+]|\\d+[.)])\\s*\\[(?:[\\sXx]|in-?progress|in_?progress|in-?review|backlog|cancelled|abandoned|done)?\\]"
        if content.range(of: taskPattern, options: .regularExpression) != nil {
            return true
        }
        // 2. HTML 任务项标记
        let htmlTaskPattern = "<input[^>]+type=[\"']checkbox[\"']|<[^>]+data-type=[\"']task_item[\"']"
        if content.range(of: htmlTaskPattern, options: .regularExpression) != nil {
            return true
        }
        // 3. 显式待办/任务清单标记
        let semanticTodoPattern = "(?mi)^\\s*(?:#{1,6}\\s*)?(?:【待办】|【任务】|\\[TODO\\]|\\[待办\\]|TODO:|待办事项|任务清单)"
        if content.range(of: semanticTodoPattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func cleanText(_ text: String) -> String {
        var res = text
        // 1. 移除 HTML 标签与代码块围栏
        res = res.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        res = res.replacingOccurrences(of: "```[a-zA-Z0-9_-]*", with: "", options: .regularExpression)
        // 2. 移除引用符与转义反斜杠
        res = res.replacingOccurrences(of: "^(?:>\\s*)+", with: "", options: .regularExpression)
        res = res.replacingOccurrences(of: "(?:^|\\s)>\\s*", with: " ", options: .regularExpression)
        res = res.replacingOccurrences(of: "\\\\([>#*`_~\\[\\]\\-\\+])", with: "$1", options: .regularExpression)
        // 3. 移除列表项目符号 (- , * , + , 1. )
        res = res.replacingOccurrences(of: "^\\s*(?:[-*+]|\\d+\\.)\\s+", with: "", options: .regularExpression)
        // 4. 移除 Markdown 链接与图片符号 [text](url) -> text
        res = res.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        // 5. 移除粗体、斜体、删除线、行内代码符号 (**text**, *text*, ~~text~~, `text`)
        res = res.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        res = res.replacingOccurrences(of: "__([^_]+)__", with: "$1", options: .regularExpression)
        res = res.replacingOccurrences(of: "~~([^~]+)~~", with: "$1", options: .regularExpression)
        res = res.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        res = res.replacingOccurrences(of: "(?<!\\w)\\*([^*]+)\\*(?!\\w)", with: "$1", options: .regularExpression)
        res = res.replacingOccurrences(of: "(?<!\\w)_([^_]+)_(?!\\w)", with: "$1", options: .regularExpression)
        // 6. 移除剩余的孤立语法符号
        res = res.replacingOccurrences(of: "(?:\\*\\*|__|~~|`)+", with: "", options: .regularExpression)
        // 7. 过滤标签（保留 C#、#123）
        res = res.replacingOccurrences(of: "#[^#\\s,]+#?", with: "", options: .regularExpression)
        res = res.replacingOccurrences(of: "#+", with: "", options: .regularExpression)
        return res.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 Markdown 里提取标题：优先第一个标题行，否则取首行前 40 字
    private func title(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let text = cleanText(String(trimmed.drop { $0 == "#" }))
                if !text.isEmpty { return String(text.prefix(40)) }
            }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                var cleaned = trimmed
                if cleaned.hasPrefix("- [") {
                    if let closeIdx = cleaned.firstIndex(of: "]") {
                        let afterClose = cleaned.index(after: closeIdx)
                        cleaned = String(cleaned[afterClose...]).trimmingCharacters(in: .whitespaces)
                    }
                } else if cleaned.hasPrefix("- ") || cleaned.hasPrefix("* ") {
                    cleaned = String(cleaned.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                if !cleaned.isEmpty {
                    return cleaned.count > 40 ? String(cleaned.prefix(40)) + "…" : cleaned
                }
            }
        }
        return "无标题"
    }

    /// 提取正文预览摘要
    private func extractSnippet(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var titleLineIndex: Int?

        // 先定位标题所在行
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                titleLineIndex = idx
                break
            }
        }
        if titleLineIndex == nil {
            for (idx, line) in lines.enumerated() {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    titleLineIndex = idx
                    break
                }
            }
        }

        for (idx, line) in lines.enumerated() {
            if let tIdx = titleLineIndex, idx == tIdx { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            var cleaned = trimmed
            if cleaned.hasPrefix("- [") {
                if let closeIdx = cleaned.firstIndex(of: "]") {
                    let afterClose = cleaned.index(after: closeIdx)
                    cleaned = String(cleaned[afterClose...]).trimmingCharacters(in: .whitespaces)
                }
            } else if cleaned.hasPrefix("- ") || cleaned.hasPrefix("* ") {
                cleaned = String(cleaned.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if cleaned.hasPrefix("#") {
                cleaned = cleaned.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            }
            cleaned = cleanText(cleaned)
            if !cleaned.isEmpty {
                return cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
            }
        }
        return ""
    }

    // MARK: - 标签提取与自动打标

    /// 检测笔记内容是否与 MCP 语义相关（大小写无关）
    static func isMcpRelated(content: String) -> Bool {
        if content.isEmpty { return false }
        let pattern = "(?i)(?:^|[^a-zA-Z0-9])mcp(?:[^a-zA-Z0-9]|$)|mcpserver|model\\s+context\\s+protocol"
        return content.range(of: pattern, options: .regularExpression) != nil
    }

    /// 从 Markdown 全文提取标签：
    /// 1. 优先提取 #标签#（双井号）或 #标签（单井号前缀，排除 Markdown 标题与 C# 等）；
    /// 2. 自动打标：若笔记内容与 MCP 相关，自动添加 "mcp" 标签。
    static func extractTags(from text: String) -> [String] {
        if text.isEmpty { return [] }
        var tags: [String] = []
        let pattern = "#([^#\\s,`]{1,16})#|#([^#\\s,`]{1,16})(?=[\\s，。！？、（）()\\[\\]{}'\"`]|$)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for m in matches {
                let matchedStr = nsText.substring(with: m.range)
                let cleaned = matchedStr.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\r\n`"))
                let isHexColor = cleaned.range(of: "^([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil
                let isPureNumber = cleaned.range(of: "^\\d+$", options: .regularExpression) != nil
                if !cleaned.isEmpty && cleaned.count <= 16 && !isHexColor && !isPureNumber {
                    tags.append(cleaned)
                }
            }
        }
        if isMcpRelated(content: text) {
            if !tags.contains(where: { $0.lowercased() == "mcp" }) {
                tags.append("mcp")
            }
        }
        var unique: [String] = []
        for t in tags {
            if !unique.contains(t) {
                unique.append(t)
            }
        }
        return Array(unique.prefix(6))
    }
}
