import Foundation
import Security
import CryptoKit

enum UsageFailure: LocalizedError {
    case message(String)
    case throttled(Date)
    case authentication
    case missingScope
    case credentialsUnavailable
    case subscriptionUsageUnavailable
    case server
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .throttled: return L10n.text("조회 요청이 많습니다. 잠시 후 다시 확인합니다.")
        case .authentication: return L10n.text("사용량 API가 인증을 거부했습니다. 해당 AI CLI의 로그인 상태를 확인하세요.")
        case .missingScope: return L10n.text("사용량 조회 권한(user:profile)이 없습니다. Claude CLI에서 다시 로그인하세요.")
        case .credentialsUnavailable: return L10n.text("Claude Desktop 또는 CLI에서 로그인해 주세요.")
        case .subscriptionUsageUnavailable: return L10n.text("이 계정에서 사용량 퍼센트를 제공하지 않습니다.")
        case .server: return L10n.text("사용량 서버에 일시적인 오류가 발생했습니다.")
        }
    }
}

/// Read-only adapters informed by Orca's rate-limit fetchers (MIT, see Resources/Orca-LICENSE).
/// Credentials remain in memory and are sent only to the provider's fixed HTTPS endpoint.
enum ExternalUsageClient {
    /// An in-memory fingerprint only; never persist or log credentials.
    static func authenticationRevision(_ provider: AIProvider) -> Data? {
        let data: Data?
        switch provider {
        case .claude:
            data = claudeOAuthCredentials().flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys)
            }
        case .grok:
            let home = ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
            data = try? Data(contentsOf: home.appendingPathComponent("auth.json"))
        case .gemini:
            data = geminiAuthenticationFingerprint()
        case .codex:
            data = nil
        }
        return data.map { Data(SHA256.hash(data: $0)) }
    }

    static func fetch(_ provider: AIProvider) throws -> QuotaSnapshot {
        switch provider {
        case .claude: return try claude()
        case .grok: return try grok()
        case .gemini: return try gemini()
        case .codex: return try QuotaClient.fetchSnapshot()
        }
    }

    static func number(_ value: Any?) -> Double? {
        guard !(value is NSNull), let value else { return nil }
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue.isFinite ? n.doubleValue : nil
        }
        if let text = value as? String, let n = Double(text), n.isFinite { return n }
        return nil
    }

    static func timestamp(_ value: Any?) -> Double? {
        if let n = number(value), n > 0 { return n > 10_000_000_000 ? n / 1000 : n }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)?.timeIntervalSince1970
    }

    static func quota(_ windows: [QuotaWindow]) -> Quota {
        Quota(primary: windows.first, secondary: windows.dropFirst().first,
              additional: Array(windows.dropFirst(2)))
    }

    static func parseClaude(_ data: [String: Any]) throws -> Quota {
        var windows: [QuotaWindow] = []
        let definitions = [("five_hour", "5시간", 300), ("seven_day", "주간", 10080),
                           ("seven_day_sonnet", "Sonnet 주간", 10080), ("seven_day_opus", "Opus 주간", 10080),
                           ("fable_weekly", "Fable 주간", 10080), ("seven_day_fable", "Fable 주간", 10080)]
        for (key, title, minutes) in definitions {
            guard let raw = data[key] as? [String: Any],
                  let percent = number(raw["utilization"] ?? raw["used_percentage"]),
                  !windows.contains(where: { $0.label == title }) else { continue }
            windows.append(QuotaWindow(usedPercent: percent, windowDurationMins: minutes,
                                       resetsAt: timestamp(raw["resets_at"]), customLabel: title))
        }
        for raw in data["limits"] as? [[String: Any]] ?? [] {
            guard let percent = number(raw["percent"]), let kind = raw["kind"] as? String else { continue }
            let model = ((raw["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let title: String
            let minutes: Int
            switch kind {
            case "session": title = "5시간"; minutes = 300
            case "weekly_all": title = "주간"; minutes = 10080
            case "weekly_scoped": title = "\(model ?? "모델") 주간"; minutes = 10080
            default: continue
            }
            if !windows.contains(where: { $0.label == title }) {
                windows.append(QuotaWindow(usedPercent: percent, windowDurationMins: minutes,
                    resetsAt: timestamp(raw["resets_at"]), customLabel: title))
            }
        }
        guard !windows.isEmpty else { throw UsageFailure.message(L10n.text("이 계정에서 구독 사용량을 제공하지 않습니다.")) }
        return quota(windows)
    }

    static func parseGrok(_ data: [String: Any]) -> Quota? {
        let config = data["config"] as? [String: Any] ?? data
        let period = config["currentPeriod"] as? [String: Any] ?? [:]
        let reset = timestamp(period["end"] ?? config["billingPeriodEnd"])
        if let percent = number(config["creditUsagePercent"]) {
            let kind = period["type"] as? String
            let monthly = kind == "USAGE_PERIOD_TYPE_MONTHLY"
            let weekly = kind == "USAGE_PERIOD_TYPE_WEEKLY"
            return quota([QuotaWindow(usedPercent: percent,
                windowDurationMins: monthly ? 43200 : weekly ? 10080 : nil, resetsAt: reset,
                customLabel: monthly ? "1개월" : weekly ? "주간" : "사용 한도")])
        }
        let limit = number((config["monthlyLimit"] as? [String: Any])?["val"])
        let used = number((config["used"] as? [String: Any])?["val"])
        guard let limit, let used, limit > 0, used >= 0 else { return nil }
        return quota([QuotaWindow(usedPercent: min(used / limit, 1) * 100, windowDurationMins: 43200,
                                  resetsAt: reset, customLabel: "1개월")])
    }

    static func recoveringClaude(oauth: () throws -> QuotaSnapshot, cli: () throws -> Quota,
                                 desktop: () -> QuotaSnapshot? = { nil }) throws -> QuotaSnapshot {
        var cliBlockedByScope: UsageFailure?
        do { return try oauth() }
        catch let error as UsageFailure {
            switch error {
            case .authentication, .credentialsUnavailable, .server: break
            case .missingScope: cliBlockedByScope = error
            default: throw error
            }
        }
        if let cached = desktop() { return cached }
        if let cliBlockedByScope { throw cliBlockedByScope }
        let result = Result { try cli() }
        // Honor throttling; a second route must not bypass the server's cooldown.
        if case .failure(UsageFailure.throttled(let date)) = result { throw UsageFailure.throttled(date) }
        // Claude itself may rotate credentials during startup. Never write tokens ourselves.
        if let refreshed = try? oauth() { return refreshed }
        return QuotaSnapshot(quota: try result.get(), account: nil)
    }

    private static func claude() throws -> QuotaSnapshot {
        try recoveringClaude(oauth: claudeOAuth, cli: ClaudeCLIUsage.fetch,
                             desktop: ClaudeDesktopUsage.fetch)
    }

    /// Use the same read-only credential source for entitlement checks and usage requests.
    /// Never infer a plan from Desktop's empty usage cache.
    static func claudeSubscriptionType() -> String? {
        guard let oauth = claudeOAuthCredentials(),
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiry = timestamp(oauth["expiresAt"]), expiry <= Date().timeIntervalSince1970 { return nil }
        return oauth["subscriptionType"] as? String
    }

    private static func claudeOAuthCredentials() -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        var services = ["Claude Code-credentials"]
        if ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil {
            let suffix = SHA256.hash(data: Data(config.path.precomposedStringWithCanonicalMapping.utf8))
                .map { String(format: "%02x", $0) }.joined().prefix(8)
            services.insert("Claude Code-credentials-\(suffix)", at: 0)
        }
        var oauth: [String: Any]?
        for service in services {
            if let data = BackgroundKeychain.read(service: service),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = root["claudeAiOauth"] as? [String: Any], value["accessToken"] is String {
                oauth = value; break
            }
        }
        if oauth == nil, let data = try? Data(contentsOf: config.appendingPathComponent(".credentials.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            oauth = root["claudeAiOauth"] as? [String: Any]
        }
        return oauth
    }

    private static func claudeOAuth() throws -> QuotaSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        let oauth = claudeOAuthCredentials()
        guard let token = oauth?["accessToken"] as? String, !token.isEmpty else {
            throw UsageFailure.credentialsUnavailable
        }
        let data = try request("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0"])
        let metadataURL = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] == nil
            ? home.appendingPathComponent(".claude.json") : config.appendingPathComponent(".claude.json")
        let metadata = (try? Data(contentsOf: metadataURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let email = (metadata?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
        return QuotaSnapshot(quota: try parseClaude(data),
            account: CodexAccount(email: email, planType: oauth?["subscriptionType"] as? String))
    }

    static func grokSession(_ root: [String: Any]) -> [String: Any]? {
        let candidates = root.sorted { $0.key < $1.key }.filter { $0.key == "https://auth.x.ai" || $0.key.hasPrefix("https://auth.x.ai::") }
        return candidates.compactMap { $0.value as? [String: Any] }.first {
            guard let token = $0["key"] as? String, !token.isEmpty else { return false }
            return timestamp($0["expires_at"]).map { $0 > Date().timeIntervalSince1970 } ?? true
        }
    }

    private static func grok() throws -> QuotaSnapshot {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        guard let bytes = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw UsageFailure.message(L10n.text("Grok CLI를 설치하고 grok login으로 로그인하세요."))
        }
        guard let session = grokSession(root), let token = session["key"] as? String else {
            throw UsageFailure.message(L10n.text("Grok을 실행해 로그인 상태를 갱신하세요. 메시지는 보낼 필요 없습니다."))
        }
        var headers = ["Authorization": "Bearer \(token)", "X-XAI-Token-Auth": "xai-grok-cli"]
        headers["x-userid"] = session["user_id"] as? String
        var data = try request("https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: headers)
        if parseGrok(data) == nil { data = try request("https://cli-chat-proxy.grok.com/v1/billing", headers: headers) }
        guard let quota = parseGrok(data) else {
            throw UsageFailure.subscriptionUsageUnavailable
        }
        let config = data["config"] as? [String: Any] ?? data
        return QuotaSnapshot(quota: quota, account: CodexAccount(email: session["email"] as? String,
            planType: config["subscriptionTier"] as? String))
    }

    private static func geminiAuthenticationFingerprint() -> Data? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let geminiDir = GeminiAvailability.geminiDirectory(home: home)
        var combined = Data()
        if let creds = try? Data(contentsOf: geminiDir.appendingPathComponent("oauth_creds.json")) {
            combined.append(creds)
        }
        let appStorage = home.appendingPathComponent("Library/Application Support/Antigravity/app_storage.json")
        if let storageData = try? Data(contentsOf: appStorage),
           let root = try? JSONSerialization.jsonObject(with: storageData) as? [String: Any],
           let username = root["jetski.onboarding.lastLoginUsername"] as? String {
            combined.append(Data(username.utf8))
        }
        return combined.isEmpty ? nil : combined
    }

    static func parseAntigravitySummary(_ data: [String: Any], userStatus: [String: Any]? = nil) -> QuotaSnapshot? {
        let root = (data["response"] as? [String: Any]) ?? data
        let groups = root["groups"] as? [[String: Any]] ?? []
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var extras: [QuotaWindow] = []

        for group in groups {
            let groupName = (group["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            for bucket in buckets {
                let bucketId = ((bucket["bucketId"] as? String) ?? "").lowercased()
                let windowKind = ((bucket["window"] as? String) ?? "").lowercased()
                let isGemini = bucketId.hasPrefix("gemini") || groupName.lowercased().contains("gemini")
                guard isGemini, let fraction = number(bucket["remainingFraction"]) else { continue }
                let clamped = max(0, min(1, fraction))
                let used = (1 - clamped) * 100
                let reset = timestamp(bucket["resetTime"])

                if bucketId == "gemini-5h" || (groupName.lowercased() == "gemini models" && windowKind == "5h") {
                    if fiveHour == nil {
                        fiveHour = QuotaWindow(usedPercent: used, windowDurationMins: 300,
                                               resetsAt: reset, customLabel: "5시간")
                    }
                } else if bucketId == "gemini-weekly" || (groupName.lowercased() == "gemini models" && windowKind == "weekly") {
                    if weekly == nil {
                        weekly = QuotaWindow(usedPercent: used, windowDurationMins: 10080,
                                             resetsAt: reset, customLabel: "주간")
                    }
                } else {
                    let shortGroup = groupName
                        .replacingOccurrences(of: "Gemini 4 ", with: "")
                        .replacingOccurrences(of: "Gemini ", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let baseLabel = shortGroup.isEmpty ? "모델" : shortGroup
                    let isWeekly = windowKind == "weekly" || bucketId.hasSuffix("-weekly")
                    let isFiveHour = windowKind == "5h" || bucketId.hasSuffix("-5h")
                    let label = isWeekly ? "\(baseLabel) 주간" : baseLabel
                    let mins = isWeekly ? 10080 : (isFiveHour ? 300 : nil)
                    if !extras.contains(where: { $0.customLabel == label }) {
                        extras.append(QuotaWindow(usedPercent: used, windowDurationMins: mins,
                                                  resetsAt: reset, customLabel: label))
                    }
                }
            }
        }

        let windows = [fiveHour, weekly].compactMap { $0 } + extras
        let account = parseAntigravityAccount(userStatus)
        if !windows.isEmpty {
            return QuotaSnapshot(quota: quota(windows), account: account)
        }
        if let userStatus {
            return parseAntigravityUserStatus(userStatus)
        }
        return nil
    }

    static func parseAntigravityAccount(_ data: [String: Any]?) -> CodexAccount? {
        guard let data else { return nil }
        let status = (data["userStatus"] as? [String: Any]) ?? data
        let email = (status["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let planStatus = status["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        let planName = (planInfo?["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (email == nil || email?.isEmpty == true) && (planName == nil || planName?.isEmpty == true) {
            return nil
        }
        return CodexAccount(email: email?.isEmpty == true ? nil : email,
                            planType: planName?.isEmpty == true ? nil : planName)
    }

    static func parseAntigravityUserStatus(_ data: [String: Any]) -> QuotaSnapshot? {
        let status = (data["userStatus"] as? [String: Any]) ?? data
        let cascade = status["cascadeModelConfigData"] as? [String: Any]
        let configs = cascade?["clientModelConfigs"] as? [[String: Any]] ?? []
        var tierBest: [String: (used: Double, reset: Double?)] = [:]

        for config in configs {
            let label = ((config["label"] as? String) ?? "").lowercased()
            guard label.contains("gemini"),
                  let quotaInfo = config["quotaInfo"] as? [String: Any],
                  let fraction = number(quotaInfo["remainingFraction"]) else { continue }
            let clamped = max(0, min(1, fraction))
            let used = (1 - clamped) * 100
            let reset = timestamp(quotaInfo["resetTime"])
            let tier: String
            if label.contains("flash") {
                tier = "Flash"
            } else if label.contains("pro") {
                tier = "Pro"
            } else {
                tier = "사용 한도"
            }
            if let existing = tierBest[tier] {
                if used > existing.used { tierBest[tier] = (used, reset ?? existing.reset) }
            } else {
                tierBest[tier] = (used, reset)
            }
        }

        let orderedTiers = ["Pro", "Flash", "사용 한도"]
        let windows = orderedTiers.compactMap { tier -> QuotaWindow? in
            guard let entry = tierBest[tier] else { return nil }
            return QuotaWindow(usedPercent: entry.used, windowDurationMins: 300,
                               resetsAt: entry.reset, customLabel: tier)
        }
        guard !windows.isEmpty else { return nil }
        return QuotaSnapshot(quota: quota(windows), account: parseAntigravityAccount(data))
    }

    static func parseGeminiCLIQuota(_ data: [String: Any], account: CodexAccount? = nil) -> QuotaSnapshot? {
        let buckets = data["buckets"] as? [[String: Any]] ?? []
        guard !buckets.isEmpty else { return nil }
        var tierBest: [String: (used: Double, reset: Double?)] = [:]

        for bucket in buckets {
            guard let fraction = number(bucket["remainingFraction"]) else { continue }
            let clamped = max(0, min(1, fraction))
            let used = (1 - clamped) * 100
            let reset = timestamp(bucket["resetTime"])
            let modelId = ((bucket["modelId"] as? String) ?? "").lowercased()
            let tier: String
            if modelId.contains("flash-lite") || modelId.contains("flash_lite") {
                tier = "Flash Lite"
            } else if modelId.contains("flash") {
                tier = "Flash"
            } else if modelId.contains("pro") {
                tier = "Pro"
            } else {
                tier = "24시간"
            }
            if let existing = tierBest[tier] {
                if used > existing.used { tierBest[tier] = (used, reset ?? existing.reset) }
            } else {
                tierBest[tier] = (used, reset)
            }
        }

        let orderedTiers = ["Pro", "Flash", "Flash Lite", "24시간"]
        let windows = orderedTiers.compactMap { tier -> QuotaWindow? in
            guard let entry = tierBest[tier] else { return nil }
            return QuotaWindow(usedPercent: entry.used, windowDurationMins: 1440,
                               resetsAt: entry.reset,
                               customLabel: tier == "24시간" ? nil : tier)
        }
        guard !windows.isEmpty else { return nil }
        return QuotaSnapshot(quota: quota(windows), account: account)
    }

    private static func gemini() throws -> QuotaSnapshot {
        if let localSnapshot = try? fetchAntigravityLocalServer() {
            return localSnapshot
        }
        if let cliSnapshot = try? fetchGeminiCLIOAuth() {
            return cliSnapshot
        }
        let dir = GeminiAvailability.geminiDirectory()
        if let settingsData = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
           let security = settings["security"] as? [String: Any],
           let auth = security["auth"] as? [String: Any],
           let selectedType = (auth["selectedType"] as? String)?.lowercased(),
           selectedType == "api-key" || selectedType == "vertex-ai" {
            throw UsageFailure.message(L10n.text("Gemini API 키 또는 Vertex AI 인증은 사용량 조회를 지원하지 않습니다."))
        }
        throw UsageFailure.message(L10n.text("Antigravity를 실행하거나 Gemini CLI에 로그인해 주세요."))
    }

    private static let antigravityEndpointLock = NSLock()
    private static var cachedAntigravityEndpoint: (base: String, headers: [String: String])?
    private static let antigravityLoopbackSession = URLSession(
        configuration: .ephemeral, delegate: LoopbackTrustDelegate(), delegateQueue: nil)

    private static func discoverAntigravityCandidates() throws -> [(base: String, headers: [String: String])] {
        let psOutput = try runCommand("/bin/ps", arguments: ["-ax", "-o", "pid=,command="])
        var candidatePID: Int32?
        var csrfToken: String?
        for line in psOutput.split(separator: "\n").map(String.init) {
            let lower = line.lowercased()
            guard lower.contains("language_server"),
                  lower.contains("antigravity"),
                  let token = extractFlag("--csrf_token", from: line) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstSpace = trimmed.firstIndex(where: { $0.isWhitespace }),
               let pid = Int32(trimmed[..<firstSpace]) {
                candidatePID = pid
                csrfToken = token
                break
            }
        }
        guard let pid = candidatePID, let token = csrfToken, !token.isEmpty else {
            throw UsageFailure.credentialsUnavailable
        }
        let lsofOutput = try runCommand("/usr/sbin/lsof", arguments: ["-Pan", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"])
        var ports: [Int] = []
        for line in lsofOutput.split(separator: "\n").map(String.init) {
            if let range = line.range(of: #":(\d+)\s+\(LISTEN\)"#, options: .regularExpression) {
                let matched = String(line[range])
                let digits = matched.dropFirst().prefix(while: { $0.isNumber })
                if let port = Int(digits), !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        guard !ports.isEmpty else { throw UsageFailure.credentialsUnavailable }
        let headers = [
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "x-codeium-csrf-token": token
        ]
        var candidates: [(base: String, headers: [String: String])] = []
        for port in ports {
            for scheme in ["http", "https"] {
                candidates.append((base: "\(scheme)://127.0.0.1:\(port)", headers: headers))
            }
        }
        return candidates
    }

    private static func postAntigravityJSON(_ path: String) throws -> [String: Any] {
        antigravityEndpointLock.lock()
        let cached = cachedAntigravityEndpoint
        antigravityEndpointLock.unlock()

        if let cached, let response = try? postLocalJSON(cached.base + path, headers: cached.headers) {
            return response
        }

        let candidates = try discoverAntigravityCandidates()
        for candidate in candidates {
            if let response = try? postLocalJSON(candidate.base + path, headers: candidate.headers) {
                antigravityEndpointLock.lock()
                cachedAntigravityEndpoint = candidate
                antigravityEndpointLock.unlock()
                return response
            }
        }
        antigravityEndpointLock.lock()
        cachedAntigravityEndpoint = nil
        antigravityEndpointLock.unlock()
        throw UsageFailure.credentialsUnavailable
    }

    private static func fetchAntigravityLocalServer() throws -> QuotaSnapshot {
        let summaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        let statusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
        let summary = try? postAntigravityJSON(summaryPath)
        let status = try? postAntigravityJSON(statusPath)
        if let summary, let snapshot = parseAntigravitySummary(summary, userStatus: status) {
            return snapshot
        }
        if let status, let snapshot = parseAntigravityUserStatus(status) {
            return snapshot
        }
        throw UsageFailure.credentialsUnavailable
    }

    static func parseAntigravityTrajectories(_ data: [String: Any]) -> (activities: [ThreadActivity], viewedAt: [String: Double]) {
        guard let summaries = data["trajectorySummaries"] as? [String: Any] else {
            return ([], [:])
        }
        var activities: [ThreadActivity] = []
        var viewedByID: [String: Double] = [:]

        for (id, rawValue) in summaries {
            guard UUID(uuidString: id) != nil,
                  let summary = rawValue as? [String: Any] else { continue }
            let annotations = summary["annotations"] as? [String: Any]
            if annotations?["archived"] as? Bool == true { continue }
            if summary["killed"] as? Bool == true { continue }
            let metadata = summary["trajectoryMetadata"] as? [String: Any]
            let parentID = (metadata?["parentConversationId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !parentID.isEmpty { continue }
            if metadata?["isBattleModeFork"] as? Bool == true { continue }
            let sourceMeta = metadata?["sourceMetadata"] as? [String: Any]
            if sourceMeta?["hideFromConversationList"] as? Bool == true { continue }
            let trajectoryType = (summary["trajectoryType"] as? String) ?? ""
            if trajectoryType == "CORTEX_TRAJECTORY_TYPE_SIDE_QUESTION"
                || trajectoryType == "CORTEX_TRAJECTORY_TYPE_COMMIT_MESSAGE_GENERATION" {
                continue
            }

            let rawTitle = (annotations?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (summary["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            let firstLineTitle = rawTitle.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = firstLineTitle.isEmpty ? L10n.text("Gemini 채팅") : firstLineTitle

            let status = (summary["status"] as? String) ?? ""
            let notFullyIdle = (summary["notFullyIdle"] as? Bool) ?? false

            let trajectoryID = (summary["trajectoryId"] as? String) ?? id
            let waitingSteps = summary["waitingSteps"] as? [[String: Any]] ?? []
            var pendingRequests = Set<PendingThreadRequest>()
            for waiting in waitingSteps {
                let stepIndex = (waiting["stepIndex"] as? NSNumber)?.intValue ?? 0
                let step = waiting["step"] as? [String: Any]
                let interaction = step?["requestedInteraction"] as? [String: Any]
                let kind: ThreadAttentionKind = interaction?["askQuestion"] != nil ? .answer : .approval
                pendingRequests.insert(PendingThreadRequest(identity: "antigravity:\(trajectoryID):\(stepIndex)", kind: kind))
            }

            let isRunning = notFullyIdle
                || status == "CASCADE_RUN_STATUS_RUNNING"
                || status == "CASCADE_RUN_STATUS_BUSY"
                || status == "CASCADE_RUN_STATUS_CANCELING"
                || !pendingRequests.isEmpty

            let modifiedAt = timestamp(summary["lastModifiedTime"]) ?? timestamp(summary["createdTime"]) ?? 0
            let inputAt = timestamp(summary["lastUserInputTime"]) ?? timestamp(summary["createdTime"]) ?? 0
            let viewed = timestamp(annotations?["lastUserViewTime"])
            if let viewed { viewedByID[id] = viewed }

            let markedAsUnread = (annotations?["markedAsUnread"] as? Bool) ?? false
            let unread = markedAsUnread || (!isRunning && viewed.map { modifiedAt > ($0 + 0.05) } != false)

            let userStepIndex = (summary["lastUserInputStepIndex"] as? NSNumber)?.intValue ?? 0
            // A step index may be reused after retries/rewinds. The user-input
            // timestamp stays stable during a turn but separates subsequent work.
            let inputIdentity = String(inputAt.bitPattern, radix: 16)
            let turnID = "step-\(max(0, userStepIndex))-\(inputIdentity)"
            let termination = ((summary["latestExecutorTerminationReason"] as? String) ?? "").uppercased()
            let turnStatus: String
            if isRunning {
                turnStatus = "inProgress"
            } else if termination.contains("ERROR") || termination.contains("FAIL") {
                turnStatus = "failed"
            } else if termination.contains("CANCEL") || termination.contains("ABORT") {
                turnStatus = "interrupted"
            } else {
                turnStatus = "completed"
            }
            let latestTurn = ThreadTurnState(
                key: "\(id):\(turnID)",
                id: turnID,
                status: turnStatus,
                startedAtMs: inputAt * 1000
            )

            activities.append(ThreadActivity(
                id: id,
                title: title,
                runtime: isRunning ? "active" : "idle",
                activeFlags: [],
                pendingRequests: pendingRequests,
                latestTurn: latestTurn,
                unread: unread,
                updatedAt: modifiedAt,
                stateConfirmed: true,
                provider: .gemini
            ))
        }
        return (activities, viewedByID)
    }

    static func fetchAntigravityTrajectories() -> (activities: [ThreadActivity], viewedAt: [String: Double])? {
        let path = "/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories"
        guard let response = try? postAntigravityJSON(path) else { return nil }
        return parseAntigravityTrajectories(response)
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let parts = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (index, part) in parts.enumerated() {
            if part == flag, index + 1 < parts.count {
                return parts[index + 1]
            }
            if part.hasPrefix(flag + "=") {
                return String(part.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    private static func runCommand(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UsageFailure.credentialsUnavailable }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func postLocalJSON(_ address: String, headers: [String: String]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.allHTTPHeaderFields = headers
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(UsageFailure.credentialsUnavailable)
        let task = antigravityLoopbackSession.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if error != nil { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            result = .success(obj)
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }

    private static func fetchGeminiCLIOAuth() throws -> QuotaSnapshot {
        let dir = GeminiAvailability.geminiDirectory()
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("oauth_creds.json")),
              let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (creds["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw UsageFailure.credentialsUnavailable
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
        let loadBody: [String: Any] = [
            "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]
        ]
        let loadResponse = try? postJSON("https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
                                         headers: headers, body: loadBody)
        var projectId: String?
        if let project = loadResponse?["cloudaicompanionProject"] as? String, !project.isEmpty {
            projectId = project
        } else if let projectDict = loadResponse?["cloudaicompanionProject"] as? [String: Any] {
            projectId = (projectDict["id"] as? String) ?? (projectDict["projectId"] as? String)
        }
        let tierDict = (loadResponse?["paidTier"] as? [String: Any]) ?? (loadResponse?["currentTier"] as? [String: Any])
        let tierId = (tierDict?["id"] as? String)?.lowercased()
        let planType: String?
        switch tierId {
        case "standard-tier": planType = "Paid"
        case "free-tier": planType = "Free"
        case "legacy-tier": planType = "Legacy"
        default: planType = nil
        }
        let email = extractEmailFromJWT(creds["id_token"] as? String)
            ?? extractLastAntigravityEmail()
        let account = (email != nil || planType != nil) ? CodexAccount(email: email, planType: planType) : nil

        var quotaBody: [String: Any] = [:]
        if let projectId, !projectId.isEmpty { quotaBody["project"] = projectId }
        let quotaResponse = try postJSON("https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
                                         headers: headers, body: quotaBody)
        guard let snapshot = parseGeminiCLIQuota(quotaResponse, account: account) else {
            throw UsageFailure.subscriptionUsageUnavailable
        }
        return snapshot
    }

    private static func extractEmailFromJWT(_ token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = (payload["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return email
    }

    private static func extractLastAntigravityEmail() -> String? {
        let appStorage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/app_storage.json")
        guard let data = try? Data(contentsOf: appStorage),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = (root["jetski.onboarding.lastLoginUsername"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return email
    }

    private static func postJSON(_ address: String, headers: [String: String], body: [String: Any]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.allHTTPHeaderFields = headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(UsageFailure.message(L10n.text("조회 시간이 초과되었습니다.")))
        let session = URLSession(configuration: .ephemeral, delegate: NoUsageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            result = Result {
                if error != nil { throw UsageFailure.message(L10n.text("네트워크 연결을 확인한 후 다시 시도하세요.")) }
                guard let response = response as? HTTPURLResponse else { throw UsageFailure.message(L10n.text("응답을 확인할 수 없습니다.")) }
                if response.statusCode == 429 {
                    let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900
                    throw UsageFailure.throttled(Date().addingTimeInterval(max(60, seconds)))
                }
                if [401, 403].contains(response.statusCode) { throw UsageFailure.authentication }
                if response.statusCode >= 500 { throw UsageFailure.server }
                guard response.statusCode == 200, let data,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw UsageFailure.message(L10n.text("사용량 조회에 실패했습니다 (HTTP %d).", response.statusCode))
                }
                return object
            }
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }

    private static func request(_ address: String, headers: [String: String]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 12)
        request.allHTTPHeaderFields = headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(UsageFailure.message(L10n.text("조회 시간이 초과되었습니다.")))
        let session = URLSession(configuration: .ephemeral, delegate: NoUsageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            result = Result {
                if error != nil { throw UsageFailure.message(L10n.text("네트워크 연결을 확인한 후 다시 시도하세요.")) }
                guard let response = response as? HTTPURLResponse else { throw UsageFailure.message(L10n.text("응답을 확인할 수 없습니다.")) }
                if response.statusCode == 429 {
                    let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900
                    throw UsageFailure.throttled(Date().addingTimeInterval(max(60, seconds)))
                }
                if response.statusCode == 403,
                   String(data: data ?? Data(), encoding: .utf8)?.contains("user:profile") == true {
                    throw UsageFailure.missingScope
                }
                if [401, 403].contains(response.statusCode) { throw UsageFailure.authentication }
                if response.statusCode >= 500 { throw UsageFailure.server }
                if response.statusCode == 412 { throw UsageFailure.message(L10n.text("이 팀 계정은 사용량 조회를 지원하지 않습니다.")) }
                guard response.statusCode == 200, let data,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw UsageFailure.message(L10n.text("사용량 조회에 실패했습니다 (HTTP %d).", response.statusCode))
                }
                return object
            }
        }
        task.resume()
        // URLSession guarantees completion after timeout/cancellation; avoid racing result reads.
        semaphore.wait()
        return try result.get()
    }
}

private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class LoopbackTrustDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        if (host == "127.0.0.1" || host == "localhost"),
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
