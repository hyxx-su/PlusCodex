import Foundation

@main
struct QuotaTests {
    static func main() throws {
        func decode(_ json: String) throws -> QuotaResponse {
            try JSONDecoder().decode(QuotaResponse.self, from: Data(json.utf8))
        }
        let legacy = try decode(#"{"rateLimits":{"primary":{"usedPercent":36,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":55,"windowDurationMins":10080}}}"#)
        assert(legacy.codex?.primary?.remaining == 64)
        assert(legacy.codex?.primary?.label == "5시간")
        assert(legacy.codex?.secondary?.remaining == 45)
        assert(legacy.codex?.secondary?.label == "주간")
        let buckets = try decode(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20}},"other":{"primary":{"usedPercent":0}}}}"#)
        assert(buckets.codex?.primary?.remaining == 80)
        let missing = try decode(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":0}}}}"#)
        assert(missing.codex == nil, "다른 모델의 한도를 Codex 한도로 표시하면 안 됨")
        assert(QuotaWindow(usedPercent: 110, windowDurationMins: nil, resetsAt: nil).remaining == 0)
        assert(QuotaWindow(usedPercent: -1, windowDurationMins: nil, resetsAt: nil).remaining == 100)
        assert(QuotaWindow(usedPercent: 36.8, windowDurationMins: nil, resetsAt: nil).remaining == 63)
        let absent = try decode(#"{"rateLimits":null}"#)
        assert(absent.codex == nil)
        assert(QuotaError.missingExecutable.isMissingExecutable)
        assert(!QuotaError.unavailable("other error").isMissingExecutable)
        let authHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let authDirectory = authHome.appendingPathComponent(".codex")
        let authFile = authDirectory.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: authHome) }
        let missingRevision = CodexAuthRevision.current(home: authHome, environment: [:])
        try Data("{}".utf8).write(to: authFile)
        let firstRevision = CodexAuthRevision.current(home: authHome, environment: [:])
        assert(firstRevision != missingRevision)
        try Data("{\"account\":\"new\"}".utf8).write(to: authFile)
        assert(CodexAuthRevision.current(home: authHome, environment: [:]) != firstRevision)
        try FileManager.default.removeItem(at: authFile)
        assert(CodexAuthRevision.current(home: authHome, environment: [:]) == missingRevision)
        print("PASS: remaining %, bucket selection, missing quota, bounds, labels")
    }
}
