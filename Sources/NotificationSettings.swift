import Foundation

enum NotificationKind: String, CaseIterable, Hashable {
    case completion
    case quota
    case reset
    case update
    case approval

    var titleKey: String {
        switch self {
        case .completion: return "작업 완료"
        case .quota: return "사용량 부족"
        case .reset: return "사용량 초기화"
        case .update: return "업데이트"
        case .approval: return "승인 요청"
        }
    }

    var descriptionKey: String {
        switch self {
        case .completion: return "요청한 작업이 완료되면 알림을 받습니다."
        case .quota: return "사용량이 부족하거나 모두 소진되면 알림을 받습니다."
        case .reset: return "사용량이 초기화되면 알림을 받습니다."
        case .update: return "새로운 버전을 사용할 수 있을 때 알림을 받습니다."
        case .approval: return "작업을 계속하기 위해 승인이 필요할 때 알림을 받습니다."
        }
    }
}

final class NotificationSettings {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled(_ kind: NotificationKind) -> Bool {
        defaults.object(forKey: key(for: kind)) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, for kind: NotificationKind) {
        guard isEnabled(kind) != enabled else { return }
        defaults.set(enabled, forKey: key(for: kind))
        onChange?()
    }

    var anyEnabled: Bool {
        NotificationKind.allCases.contains { isEnabled($0) }
    }

    private func key(for kind: NotificationKind) -> String {
        "notifications.\(kind.rawValue).enabled"
    }
}
