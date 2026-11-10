import Foundation
import CryptoKit
import Security

struct ContentCipher: Sendable {
    private let encryption: SymmetricKey
    private let fingerprint: SymmetricKey
    init(master: SymmetricKey) {
        encryption = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("Shiying.v1".utf8), info: Data("content".utf8), outputByteCount: 32)
        fingerprint = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("Shiying.v1".utf8), info: Data("deduplication".utf8), outputByteCount: 32)
    }
    func seal(_ data: Data, context: String) throws -> Data {
        guard let result = try AES.GCM.seal(data, using: encryption, authenticating: Data(context.utf8)).combined else { throw ShiyingError.key }
        return result
    }
    func open(_ data: Data, context: String) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryption, authenticating: Data(context.utf8)) }
        catch { throw ShiyingError.authentication }
    }
    /// Explicit length framing is stable across process launches and encoder versions.
    /// Stream representations instead of allocating another full image archive for hashing.
    func digest(_ payload: ClipPayload) -> Data {
        var hmac = HMAC<SHA256>(key: fingerprint)
        func frame(_ value: Int) {
            var number = UInt64(value).bigEndian
            withUnsafeBytes(of: &number) { hmac.update(data: Data($0)) }
        }
        hmac.update(data: Data("Shiying.payload.v1".utf8)); frame(payload.items.count)
        for item in payload.items {
            let reps = item.representations.sorted { $0.type < $1.type }
            frame(reps.count)
            for rep in reps {
                let type = Data(rep.type.utf8); frame(type.count); hmac.update(data: type)
                frame(rep.data.count); hmac.update(data: rep.data)
            }
        }
        return Data(hmac.finalize())
    }
    func digest(_ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: fingerprint)) }
}

enum InstallationKey {
    enum Interaction: Sendable { case background, userInitiated }
    // 文件型 login Keychain 的交互开关是进程级；本应用全部密钥访问在此
    // 同步互斥区完成，不能跨 await，也不能将“允许 UI”留给后台任务。
    private static let interactionLock = NSLock()
    static func withInteraction<T>(_ interaction: Interaction, operation: () throws -> T) throws -> T {
        interactionLock.lock(); defer { interactionLock.unlock() }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(interaction == .userInitiated) == errSecSuccess else { throw ShiyingError.key }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }
    static func load(allowCreate: Bool, interaction: Interaction = .background) throws -> SymmetricKey {
        try withInteraction(interaction) { try loadKey(allowCreate: allowCreate) }
    }
    private static func loadKey(allowCreate: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.shiying.mac") + ".history", kSecAttrAccount as String: "installation-v1",
            kSecAttrSynchronizable as String: false]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 { return SymmetricKey(data: bytes) }
        if needsAuthorization(status) { throw ShiyingError.keyAuthorization }
        guard status == errSecItemNotFound, allowCreate else { throw ShiyingError.key }
        let key = SymmetricKey(size: .bits256)
        var item = query
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if needsAuthorization(added) { throw ShiyingError.keyAuthorization }
        guard added == errSecSuccess else { throw ShiyingError.key }
        return key
    }
    static func needsAuthorization(_ status: OSStatus) -> Bool {
        [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled].contains(status)
    }
}
