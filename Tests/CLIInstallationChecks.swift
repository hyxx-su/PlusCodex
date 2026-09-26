import Foundation

@main struct CLIInstallationChecks {
    static func main() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("PlusCodex-cli-installation-\(UUID().uuidString)")
        try fileManager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixture) }

        func executable(_ relativePath: String, permissions: Int = 0o755) throws -> URL {
            let url = fixture.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            return url
        }

        let bundle = fixture.appendingPathComponent("ChatGPT.app")
        let modern = try executable("ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let shim = try executable("ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        let legacy = try executable("ChatGPT.app/Contents/Resources/codex")
        let standalone = try executable("standalone/bin/codex")
        let standaloneDirectory = standalone.deletingLastPathComponent().path
        func selected() -> String? {
            CLIInstallation.codexExecutable(appBundles: [bundle], directories: [standaloneDirectory])
        }
        precondition(selected() == modern.path)
        try fileManager.removeItem(at: modern)
        precondition(selected() == shim.path)
        try fileManager.removeItem(at: shim)
        precondition(selected() == legacy.path)
        try fileManager.removeItem(at: legacy)
        precondition(selected() == standalone.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: standalone.path)
        precondition(selected() == nil, "A non-executable CLI must not be launched")

        let claude = try executable(".local/bin/claude")
        let grok = try executable(".local/bin/grok")
        precondition(CLIInstallation.executable(.claude, home: fixture, environment: ["PATH": ""])
            == claude.path)
        precondition(CLIInstallation.executable(.grok, home: fixture, environment: ["PATH": ""])
            == grok.path)
        let pathClaude = try executable("custom/bin/claude")
        precondition(CLIInstallation.executable(.claude, home: fixture,
            environment: ["PATH": pathClaude.deletingLastPathComponent().path]) == pathClaude.path)
        print("PASS: Codex app bundle, legacy and standalone fallback, non-executable rejection, Claude/Grok CLI paths")
    }
}
