import CodexBarCore
import Foundation
import Testing

struct CodexBarConfigHooksTests {
    @Test
    func `hooks survive config round trip`() throws {
        let hooks = HooksConfig(
            enabled: true,
            events: [
                HookRule(
                    id: "quota-low",
                    event: .quotaLow,
                    provider: "codex",
                    threshold: 0.9,
                    executable: "/usr/bin/true",
                    timeoutSeconds: 30),
            ])
        let config = CodexBarConfig(
            providers: [ProviderConfig(id: .codex, enabled: true)],
            hooks: hooks)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(decoded.hooks == hooks)
    }
}

struct CodexBarConfigShareUsageTests {
    private static let legacyJSON = Data(#"{"version":1,"providers":[{"id":"codex","enabled":true}]}"#.utf8)

    @Test
    func `legacy config without the key loads off and saves without adding it`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarConfigShareUsageTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.legacyJSON.write(to: url)
        let store = CodexBarConfigStore(fileURL: url)

        let loaded = try #require(try store.load())
        #expect(loaded.shareUsageWithCLI == false)
        #expect(loaded.providers.first { $0.id == .codex }?.enabled == true)

        try store.save(loaded)
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(!rewritten.contains("shareUsageWithCLI"))
        #expect(try #require(try store.load()).shareUsageWithCLI == false)
    }

    @Test
    func `enabled flag round trips through the store`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarConfigShareUsageTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CodexBarConfigStore(fileURL: url)
        var config = try CodexBarConfig.decode(from: Self.legacyJSON)
        config.shareUsageWithCLI = true

        try store.save(config)

        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"shareUsageWithCLI\""))
        #expect(try #require(try store.load()).shareUsageWithCLI == true)
    }
}
