import Foundation

/// Pure presentation: named windows are selected by duration, never by array position.
enum MenuBarFormat {
    static let defaultFormat = "{auto}%"
    static let maximumLength = 80
    static let presets = [defaultFormat, "{auto_time}", "{auto}% | {auto_time}", "{5h}% | {1w}%"]

    struct HelpEntry {
        let token: String
        let detail: String
    }
    struct HelpSection {
        let title: String
        let entries: [HelpEntry]
    }

    private static func isArgon(_ window: QuotaWindow) -> Bool {
        (window.customLabel ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains("argon")
    }

    private static func helpWindows(quota: Quota) -> [(key: String, window: QuotaWindow)] {
        let windows = quota.windows
        let five = windows.firstIndex { $0.windowDurationMins == 300 }
        let weekly = windows.firstIndex { $0.windowDurationMins == 10080 }
        let argon = windows.firstIndex { isArgon($0) && $0.windowDurationMins == 10080 }
            ?? windows.firstIndex(where: isArgon)
        return windows.prefix(20).enumerated().map { index, window in
            let key = index == argon ? "argon" : index == five ? "5h" : index == weekly ? "1w" : String(index + 1)
            return (key, window)
        }
    }

    static func helpSections(quota: Quota?) -> [HelpSection] {
        guard let quota, !quota.windows.isEmpty else {
            return [HelpSection(title: L10n.text("기본 토큰"), entries: [
                HelpEntry(token: defaultFormat, detail: L10n.text("한도 자동 선택"))
            ])]
        }
        let available = helpWindows(quota: quota)
        var basic: [HelpEntry] = []
        var time: [HelpEntry] = []
        if let automatic = window("auto", quota: quota) {
            basic.append(HelpEntry(token: defaultFormat, detail: L10n.text("%@ 사용량", automatic.label)))
            if let reset = automatic.resetsAt, reset.isFinite {
                time.append(HelpEntry(token: "{auto_time}", detail: L10n.text("자동 선택 한도 초기화")))
            }
        }
        for (key, window) in available {
            basic.append(HelpEntry(token: "{\(key)}%", detail: L10n.text("%@ 사용량", window.label)))
            if let reset = window.resetsAt, reset.isFinite {
                time.append(HelpEntry(token: "{\(key)_time}", detail: L10n.text("%@ 초기화까지", window.label)))
            }
        }
        var sections = [HelpSection(title: L10n.text("기본 토큰"), entries: basic)]
        if !time.isEmpty { sections.append(HelpSection(title: L10n.text("초기화 시간"), entries: time)) }
        return sections
    }

    static func presets(quota: Quota?) -> [String] {
        var values = [defaultFormat]
        let automatic = window("auto", quota: quota)
        if let timestamp = automatic?.resetsAt, timestamp.isFinite {
            values += ["{auto_time}", "{auto}% | {auto_time}"]
        }
        if window("5h", quota: quota) != nil && window("1w", quota: quota) != nil {
            values.append("{5h}% | {1w}%")
        }
        if let count = quota?.windows.count, count > 2 {
            if let quota {
                values.append(helpWindows(quota: quota).prefix(3).map { "{\($0.key)}%" }.joined(separator: " | "))
            }
        }
        return values
    }

    static func helpText(provider: AIProvider, quota: Quota?) -> String {
        var lines = [L10n.text("%@ 표시 토큰", provider.name)]
        guard let quota else {
            return (lines + [L10n.text("아직 조회된 한도가 없습니다. 사용량을 조회하면 이 AI에서 쓸 수 있는 토큰을 안내합니다."),
                             L10n.text("기본 형식: {auto}% · 빈칸: 아이콘만 표시")]).joined(separator: "\n\n")
        }
        guard !quota.windows.isEmpty else {
            return (lines + [L10n.text("현재 계정은 표시할 사용량 한도를 제공하지 않습니다.")]).joined(separator: "\n\n")
        }
        lines.append(L10n.text("현재 제공되는 한도 기준입니다. %는 숫자 토큰 뒤에 직접 입력하세요."))
        for section in helpSections(quota: quota) {
            lines.append(section.title)
            lines += section.entries.map { "\($0.token) — \($0.detail)" }
        }
        lines.append(L10n.text("_time: 초기화까지 남은 시간 · 초기화 시각이 제공되는 한도만 지원"))
        lines.append(L10n.text("문자·구분자 조합 가능 · 최대 80자\n빈칸: 아이콘만 표시 · 미제공 값: —"))
        return lines.joined(separator: "\n")
    }

    private enum Metric { case percent, time }
    private struct Token {
        let window: String
        let metric: Metric
    }
    private enum Part { case literal(String), value(Token) }
    enum ValidationError: Error { case invalid }

    private static func token(_ value: String) -> Token? {
        var window = value
        var metric = Metric.percent
        if value.hasSuffix("_time") {
            window = String(value.dropLast(5))
            metric = .time
        }
        if ["auto", "5h", "1w", "argon"].contains(window) { return Token(window: window, metric: metric) }
        // Numbered buckets let providers expose model-specific/additional limits too.
        if let number = Int(window), (1...20).contains(number), String(number) == window {
            return Token(window: window, metric: metric)
        }
        return nil
    }

    private static func parse(_ format: String) throws -> [Part] {
        guard format.count <= maximumLength,
              !format.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationError.invalid
        }
        var parts: [Part] = []
        var literal = ""
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            if character == "{" {
                if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
                guard let end = format[index...].firstIndex(of: "}"),
                      let value = token(String(format[format.index(after: index)..<end])) else {
                    throw ValidationError.invalid
                }
                parts.append(.value(value))
                index = format.index(after: end)
            } else {
                guard character != "}" else { throw ValidationError.invalid }
                literal.append(character)
                index = format.index(after: index)
            }
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        return parts
    }

    static func isValid(_ format: String) -> Bool { (try? parse(format)) != nil }

    private static func window(_ name: String, quota: Quota?) -> QuotaWindow? {
        let windows = quota?.windows ?? []
        switch name {
        case "5h": return windows.first { $0.windowDurationMins == 300 }
        case "1w": return windows.first { $0.windowDurationMins == 10080 }
        case "argon":
            return windows.first { isArgon($0) && $0.windowDurationMins == 10080 }
                ?? windows.first(where: isArgon)
        case "auto":
            return window("5h", quota: quota) ?? window("1w", quota: quota) ?? windows.first
        default:
            guard let number = Int(name), windows.indices.contains(number - 1) else { return nil }
            return windows[number - 1]
        }
    }

    static func render(_ format: String, quota: Quota?, showRemaining: Bool = true,
                       now: Date = Date(), language: AppLanguage = L10n.language) -> String {
        let parts = (try? parse(format)) ?? (try! parse(defaultFormat))
        return parts.map { part in
            switch part {
            case .literal(let value): return value
            case .value(let token):
                guard let window = window(token.window, quota: quota) else { return quota == nil ? "…" : "—" }
                switch token.metric {
                case .time: return countdown(window.resetsAt, now: now, language: language)
                case .percent:
                    guard window.usedPercent.isFinite else { return "—" }
                    return String(window.displayPercent(showRemaining: showRemaining))
                }
            }
        }.joined()
    }

    private static func countdown(_ timestamp: Double?, now: Date, language: AppLanguage) -> String {
        guard let timestamp, timestamp.isFinite else { return "—" }
        let minutes = ceil(max(0, timestamp - now.timeIntervalSince1970) / 60)
        guard minutes.isFinite, minutes < Double(Int.max) else { return "—" }
        let value = Int(minutes), days = Int(minutes) / 1440, hours = Int(minutes) / 60 % 24
        let units = language == .korean ? ["일", "시간", "분"] : ["d", "h", "m"]
        if days > 0 { return "\(days)\(units[0]) \(hours)\(units[1])" }
        if value >= 60 { return "\(value / 60)\(units[1]) \(value % 60)\(units[2])" }
        return "\(value)\(units[2])"
    }
}
