import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct SpendDashboardCodexAutoReviewTests {
    /// Scanner-driven: free Auto-review requests next to a priced model must not make Codex cost a lower bound.
    @Test
    func `free auto review requests do not mark codex cost as a lower bound`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        let timestamp = env.isoString(for: day)
        for (id, model, input, creator) in [
            ("priced", "gpt-5.4", 100_000, nil),
            ("review", "codex-auto-review", 50000, "acct-fixture"),
        ] as [(String, String, Int, String?)] {
            var meta: [String: Any] = ["id": id]
            if let creator { meta["creator_account_id"] = creator }
            _ = try env.writeCodexSessionFile(day: day, filename: "\(id).jsonl", contents: env.jsonl([
                ["type": "session_meta", "timestamp": timestamp, "payload": meta],
                ["type": "turn_context", "timestamp": timestamp, "payload": ["model": model]],
                ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": id]],
                ["type": "event_msg", "timestamp": timestamp, "payload": [
                    "type": "token_count",
                    "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0]],
                ]],
            ]))
        }
        let report = try CostUsageCodexAutoReviewTests.report(
            CostUsageCodexAutoReviewTests.scannedCache(day: day, env: env), day: day)
        let summary = try #require(report.summary)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: summary.totalTokens,
            sessionCostUSD: summary.totalCostUSD,
            last30DaysTokens: summary.totalTokens,
            last30DaysCostUSD: summary.totalCostUSD,
            costProvenance: .listPriceEstimate,
            daily: report.data,
            hourly: report.hourly,
            quotaSlices: report.quotaSlices,
            updatedAt: day)
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Codex", snapshot: snapshot)],
            requestedDays: 30,
            now: day,
            calendar: .current)
        let group = try #require(model.groups.first)
        let cost = try #require(group.totalCost)

        #expect(cost > 0)
        #expect(group.hasPartialCost == false)
        #expect(group.dailySummaries.allSatisfy { !$0.hasPartialCost })
        #expect(group.models.first { $0.modelName == "codex-auto-review" }?.totalTokens == 50000)
        #expect(!spendDashboardMetricText(
            cost: group.totalCost, tokens: nil, currencyCode: "USD", costIsLowerBound: group.hasPartialCost)
            .contains("≥"))
        #expect(group.coverage.unpriced == 0)
        #expect(group.coverage.unmetered == 0)

        let payload = CodexBarCLI.makeCostPayload(provider: .codex, snapshot: snapshot, error: nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let coverage = try #require(json["coverage"] as? [String: Any])
        #expect(coverage["unpriced"] as? Int == 0)
        #expect(coverage["unmetered"] as? Int == 0)
    }
}
