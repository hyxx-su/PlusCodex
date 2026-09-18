import ServiceManagement
import Foundation

/// Read the OS status rather than maintaining a second login-item flag.
final class LoginLaunchController {
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard,
         readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.defaults = defaults; self.readStatus = readStatus
        self.register = register; self.unregister = unregister
    }
    var requested: Bool { readStatus() == .enabled || readStatus() == .requiresApproval }
    var message: String {
        switch readStatus() {
        case .enabled: return "Mac에 로그인하면 자동으로 실행합니다."
        case .requiresApproval: return "시스템 설정 → 일반 → 로그인 항목에서 허용하세요."
        case .notFound: return "응용 프로그램 폴더에 설치한 뒤 켜주세요."
        default: return "Mac에 로그인할 때 PlusCodex를 실행합니다."
        }
    }
    func applyInitialDefault() throws {
        guard !defaults.bool(forKey: "loginItemDefaultApplied.v1") else { return }
        if !requested { try register() }
        defaults.set(true, forKey: "loginItemDefaultApplied.v1")
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled && !requested { try register() }
        else if !enabled && requested { try unregister() }
        // An explicit choice always wins over future launches and updates.
        defaults.set(true, forKey: "loginItemDefaultApplied.v1")
    }
}
