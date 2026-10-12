import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexAutoReviewTests {
    @Test
    func `only ChatGPT auto review from the cutoff is free across cache refreshes`() throws {
        let cutoff = Date(timeIntervalSince1970: 1_791_270_000)
        for creator in [nil, " \n", "account-fixture"] as [String?] {
            for instant in [cutoff.addingTimeInterval(-1), cutoff] {
                let env = try CostUsageTestEnvironment()
                defer { env.cleanup() }
                let timestamp = env.isoString(for: instant)
                var metadata: [String: Any] = ["id": "review-fixture"]
                if let creator { metadata["creator_account_id"] = creator }
                let contents = try env.jsonl([
                    ["type": "session_meta", "timestamp": timestamp, "payload": metadata],
                    ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "codex-auto-review"]],
                    ["type": "event_msg", "timestamp": timestamp, "payload": [
                        "type": "token_count",
                        "info": ["last_token_usage": [
                            "input_tokens": 1000, "cached_input_tokens": 200, "output_tokens": 100,
                        ]],
                    ]],
                ])
                _ = try env.writeCodexSessionFile(day: instant, filename: "review.jsonl", contents: contents)
                var options = CostUsageScanner.Options(
                    codexSessionsRoot: env.codexSessionsRoot,
                    claudeProjectsRoots: nil,
                    cacheRoot: env.cacheRoot,
                    codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
                options.refreshMinIntervalSeconds = 0
                let isFree = creator == "account-fixture" && instant >= cutoff
                for refresh in 0..<3 {
                    if refresh == 2 {
                        var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
                        for path in legacy.files.keys {
                            legacy.files[path]?.codexSession = nil
                            legacy.files[path]?.codexParserRevision = CostUsageFileUsage.currentCodexParserRevision - 1
                        }
                        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy)
                    }
                    _ = CostUsageScanner.loadDailyReport(
                        provider: .codex, since: instant, until: instant, now: cutoff, options: options)
                    let report = CostUsageScanner.buildCodexReportFromCache(
                        cache: CostUsageStoreAccess.read(cacheRoot: env.cacheRoot),
                        range: .init(since: instant, until: instant),
                        modelsDevCatalog: ModelsDevCatalog(providers: [:]))
                    let entry = try #require(report.data.first)
                    #expect(entry.totalTokens == 1100)
                    #expect(entry.cacheReadTokens == 200)
                    #expect(entry.coverageCounts.unmetered == 0)
                    #expect(entry.coverageCounts.unpriced == (isFree ? 0 : 1))
                    #expect(entry.costUSD == (isFree ? 0 : nil))
                    #expect(entry.modelBreakdowns?.first?.costUSD == (isFree ? 0 : nil))
                    #expect(report.quotaSlices.first?.costIsComplete == isFree)
                    #expect(report.quotaSlices.first?.costUSD == (isFree ? 0 : nil))
                    #expect(report.hourly.first?.costIsComplete == isFree)
                }
            }
        }
    }
}
