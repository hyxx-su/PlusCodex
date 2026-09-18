import Foundation
import Security
import LocalAuthentication

enum BackgroundKeychain {
    private static let lock = NSLock()

    /// SecItem's UI flags alone do not suppress legacy file-keychain ACL prompts.
    /// Scope the process-local legacy switch to this synchronous read and restore it.
    /// No ACL, stored credential, or system keychain setting is changed.
    static func read(service: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let result = withoutInteraction(get: {
            var allowed: DarwinBoolean = false
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        }, set: { SecKeychainSetUserInteractionAllowed($0) }, operation: {
            let context = LAContext()
            context.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context
            ]
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            return (status, value as? Data)
        })
        return result.0 == errSecSuccess ? result.1 : nil
    }

    /// Dependency-injected policy check: tests never read real credentials or show prompts.
    static func withoutInteraction(get: () -> (OSStatus, Bool), set: (Bool) -> OSStatus,
                                   operation: () -> (OSStatus, Data?)) -> (OSStatus, Data?) {
        let (status, previous) = get()
        guard status == errSecSuccess else { return (status, nil) }
        let disabled = set(false)
        guard disabled == errSecSuccess else { return (disabled, nil) }
        defer { _ = set(previous) }
        return operation()
    }
}
