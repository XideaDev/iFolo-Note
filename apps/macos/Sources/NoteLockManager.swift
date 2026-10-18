import Foundation
import CryptoKit
import LocalAuthentication
import Security

public enum NoteLockError: LocalizedError {
    case authenticationFailed(String)
    case userCancelled
    case invalidEnvelope
    case keyDerivationFailed
    case decryptionFailed
    case notLocked
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason): return "身份验证未通过: \(reason)"
        case .userCancelled: return "用户取消了身份验证"
        case .invalidEnvelope: return "密文数据格式错误或已被破坏"
        case .keyDerivationFailed: return "无法获取或生成安全加密密钥"
        case .decryptionFailed: return "笔记解密失败，密文已被损坏或校验未通过"
        case .notLocked: return "该笔记当前未加密"
        case .keychainError(let status): return "钥匙串访问异常，状态码: \(status)"
        }
    }
}

/// 单篇笔记隐私锁与保险箱加密管理器
public final class NoteLockManager {
    public static let shared = NoteLockManager()

    /// 密文文件封包前置魔数 (8 Bytes)
    public let magicHeader = Data("IFOLO_LK".utf8)
    public let currentVersion: UInt8 = 0x01

    private let keychainService = "com.ifolo.desktop.notelock"
    private let keychainAccount = "master-note-lock-key"

    // 内存短期会话密钥缓存（解锁后暂存，超时或切出时自动清理）
    private var cachedSessionKey: SymmetricKey?
    private let sessionLock = NSLock()
    private var autoLockWorkItem: DispatchWorkItem?
    public var autoLockTimeout: TimeInterval = 300 // 默认 300s (5分钟)

    public func setAutoLockTimeout(_ seconds: TimeInterval) {
        sessionLock.lock()
        self.autoLockTimeout = seconds
        sessionLock.unlock()
        touchSession()
        Log.write("NoteLockManager: 已更新免密会话超时为 \(seconds) 秒")
    }

    private init() {
        if let savedTimeout = UserDefaults.standard.object(forKey: "ifolo.vaultTimeout") as? Double {
            self.autoLockTimeout = savedTimeout
        }
    }
    // MARK: - 判定

    /// 判定给定的二进制数据是否为加密笔记封包
    public func isEncryptedData(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return data.prefix(8) == magicHeader
    }

    /// 当前内存是否持有已验证的解锁密钥会话
    public var hasActiveSession: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return cachedSessionKey != nil
    }

    /// 获取当前会话密钥（若已在有效会话中）
    public func currentSessionKey() -> SymmetricKey? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return cachedSessionKey
    }

    // MARK: - 身份认证与会话管理

    /// 请求生物识别或系统密码授权，成功后建立会话并返回密钥
    public func authenticate(reason: String = "解锁受保护的私密笔记与保险箱", completion: @escaping (Result<SymmetricKey, NoteLockError>) -> Void) {
        sessionLock.lock()
        if let existingKey = cachedSessionKey {
            sessionLock.unlock()
            touchSession()
            completion(.success(existingKey))
            return
        }
        sessionLock.unlock()

        let context = LAContext()
        context.localizedCancelTitle = "取消"

        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // 环境不支持或未设置锁屏密码时，降级或提示
            let msg = authError?.localizedDescription ?? "设备未开启密码或 Touch ID 保护"
            Log.write("LocalAuthentication canEvaluatePolicy 失败: \(msg)")
            // 尝试直接从钥匙串提取已存密钥（如无交互可用）
            if let directKey = try? retrieveOrCreateMasterKey(allowPrompt: false) {
                self.saveSession(key: directKey)
                completion(.success(directKey))
                return
            }
            completion(.failure(.authenticationFailed(msg)))
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            guard let self = self else { return }
            if success {
                do {
                    let key = try self.retrieveOrCreateMasterKey(allowPrompt: true)
                    self.saveSession(key: key)
                    DispatchQueue.main.async {
                        completion(.success(key))
                    }
                } catch let err as NoteLockError {
                    DispatchQueue.main.async { completion(.failure(err)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(.keyDerivationFailed)) }
                }
            } else {
                let errResult: NoteLockError
                if let laError = error as? LAError, laError.code == .userCancel {
                    errResult = .userCancelled
                } else {
                    errResult = .authenticationFailed(error?.localizedDescription ?? "鉴权失败")
                }
                DispatchQueue.main.async {
                    completion(.failure(errResult))
                }
            }
        }
    }

    /// 手动或超时立即上锁：彻底清除内存中的明文会话密钥
    public func lockSession() {
        sessionLock.lock()
        cachedSessionKey = nil
        autoLockWorkItem?.cancel()
        autoLockWorkItem = nil
        sessionLock.unlock()
        Log.write("NoteLockManager: 内存解锁会话已彻底销毁并复锁")
    }

    private func saveSession(key: SymmetricKey) {
        sessionLock.lock()
        cachedSessionKey = key
        sessionLock.unlock()
        touchSession()
    }

    /// 延长会话活跃期
    /// 延长会话活跃期
    public func touchSession() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        autoLockWorkItem?.cancel()
        autoLockWorkItem = nil

        if autoLockTimeout < 0 {
            // -1: 直至退出模式，本次进程存活期间不挂载倒计时，应用退出或完全关闭时立即失效
            return
        }

        if autoLockTimeout == 0 {
            // 0: 立即锁定模式，给予短暂缓冲（0.5s）确保当前读写事务安全落地后即刻复锁
            let work = DispatchWorkItem { [weak self] in
                self?.lockSession()
            }
            autoLockWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return
        }

        // > 0: 定时自动复锁
        let work = DispatchWorkItem { [weak self] in
            self?.lockSession()
        }
        autoLockWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoLockTimeout, execute: work)
    }

    // MARK: - AES-256-GCM 加解密信封核心

    /// 将 Markdown 明文加密为安全封包
    public func encrypt(markdown: String, with key: SymmetricKey) throws -> Data {
        let plaintextData = Data(markdown.utf8)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintextData, using: key, nonce: nonce)

        var envelope = Data()
        envelope.reserveCapacity(8 + 1 + 12 + 16 + sealedBox.ciphertext.count)
        envelope.append(magicHeader)           // 8B 魔数
        envelope.append(currentVersion)        // 1B 版本号
        envelope.append(contentsOf: nonce)    // 12B Nonce
        envelope.append(sealedBox.tag)         // 16B 认证标签 (Auth Tag)
        envelope.append(sealedBox.ciphertext)  // 密文正文
        return envelope
    }

    /// 将安全封包解密还原为 Markdown 明文
    public func decrypt(envelopeData: Data, with key: SymmetricKey) throws -> String {
        guard isEncryptedData(envelopeData) else {
            throw NoteLockError.invalidEnvelope
        }

        let minSize = 8 + 1 + 12 + 16
        guard envelopeData.count >= minSize else {
            throw NoteLockError.invalidEnvelope
        }

        let version = envelopeData[8]
        guard version == currentVersion else {
            throw NoteLockError.invalidEnvelope
        }

        let nonceBytes = envelopeData.subdata(in: 9..<21)
        let tagBytes = envelopeData.subdata(in: 21..<37)
        let ciphertext = envelopeData.subdata(in: 37..<envelopeData.count)

        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes) else {
            throw NoteLockError.invalidEnvelope
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagBytes)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            guard let string = String(data: decryptedData, encoding: .utf8) else {
                throw NoteLockError.decryptionFailed
            }
            return string
        } catch {
            throw NoteLockError.decryptionFailed
        }
    }

    // MARK: - 钥匙串管理 (Keychain)

    private func retrieveOrCreateMasterKey(allowPrompt: Bool) throws -> SymmetricKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowPrompt {
            let ctx = LAContext()
            ctx.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = ctx
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }

        if status == errSecItemNotFound {
            // 首次使用生成 256 位安全对称主密钥
            let newKey = SymmetricKey(size: .bits256)
            let rawData = newKey.withUnsafeBytes { Data($0) }

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecValueData as String: rawData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                Log.write("NoteLockManager: 成功在系统钥匙串中生成并持久化主加密密钥")
                return newKey
            } else {
                Log.write("NoteLockManager: 写入系统钥匙串失败: \(addStatus)")
                throw NoteLockError.keychainError(addStatus)
            }
        }

        throw NoteLockError.keychainError(status)
    }
}
