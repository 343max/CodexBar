import Foundation
import Testing
@testable import CodexBarCore

/// Codex Auto-review checks stopped drawing from plan usage for ChatGPT sign-in on 2026-10-06.
/// Those requests are priced at an exact $0: their tokens stay visible and they carry no unpriced marker.
@Suite(.serialized)
struct CostUsageCodexAutoReviewTests {
    static let autoReview = "codex-auto-review"

    @Test
    func `auto review after the cutoff in a ChatGPT session is priced at zero`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        _ = try Self.writeSession(env: env, day: day, id: "review", model: Self.autoReview, creator: "acct-fixture")
        let cache = try Self.scannedCache(day: day, env: env)

        let report = Self.report(cache, day: day)
        let entry = try #require(report.data.first)
        let breakdown = try #require(entry.modelBreakdowns?.first { $0.modelName == Self.autoReview })

        #expect(cache.files.values.first?.codexSession?.hasCreatorAccount == true)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.unmeteredRequestCount == nil)
        #expect(entry.coverageCounts.unpriced == 0)
        #expect(entry.coverageCounts.unmetered == 0)
        #expect(entry.coverageCounts.priced > 0)
        #expect(entry.totalTokens == 300_000)
        #expect(breakdown.totalTokens == 300_000)
        #expect(breakdown.costUSD == 0)
        #expect(entry.costUSD == 0)
        #expect(report.summary?.totalTokens == 300_000)
        #expect(report.summary?.totalCostUSD == 0)
        #expect(report.hourly.allSatisfy { $0.costUSD == 0 && $0.costIsComplete })
        #expect(report.quotaSlices.allSatisfy { $0.costUSD == 0 && $0.costIsComplete })
    }

    /// The quota window must not read free requests as missing tokens or unknown cost.
    @Test
    func `the quota window for a free auto review day is complete`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        _ = try Self.writeSession(env: env, day: day, id: "review", model: Self.autoReview, creator: "acct-fixture")
        let report = try Self.report(Self.scannedCache(day: day, env: env), day: day)
        let week = try #require(Self.currentQuotaWeek(report, day: day))

        #expect(week.totalTokens == 300_000)
        #expect(week.totalCostUSD == 0)
        #expect(week.tokensAreComplete)
        #expect(week.costIsComplete)
    }

    /// A missing-parent fork on the same day keeps its unmetered semantics next to free requests.
    @Test
    func `a missing parent fork beside free auto review keeps fork semantics`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        var fork = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: cutoff + 2000, size: 1, days: [:], parsedBytes: 1, codexRows: [], codexScanComplete: true)
        fork.forkedFromId = "missing-parent"
        fork.forkBaselineDependencyKey = "missing|missing-parent"
        fork.codexSession = Self.session(id: "fork", hasCreatorAccount: true, startedAtUnixMs: cutoff + 2000)
        let report = Self.report(
            rows: [Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000)],
            hasCreatorAccount: true,
            extraFiles: ["/fork.jsonl": fork])
        let entry = try #require(report.data.first)

        #expect(entry.unmeteredRequestCount == 1)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.costUSD == 0)
        #expect(entry.totalTokens == 1010)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: report.data,
            quotaSlices: report.quotaSlices,
            updatedAt: Self.cutoffNoon)
        let week = try #require(snapshot.quotaWeekSummaries(
            resetAt: Self.cutoffNoon.addingTimeInterval(3 * 86400),
            now: Self.cutoffNoon,
            calendar: Self.pacific).first)
        #expect(!week.tokensAreComplete)
        #expect(!week.costIsComplete)
    }

    @Test
    func `auto review before the cutoff stays unpriced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 4)
        _ = try Self.writeSession(env: env, day: day, id: "review", model: Self.autoReview, creator: "acct-fixture")
        let entry = try #require(Self.report(Self.scannedCache(day: day, env: env), day: day).data.first)

        #expect(entry.unpricedRequestCount == 2)
        #expect(entry.costUSD == nil)
        #expect(entry.modelBreakdowns?.first?.costUSD == nil)
        #expect(entry.totalTokens == 300_000)
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func `auto review without a ChatGPT creator account stays unpriced`(creator: String?) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        _ = try Self.writeSession(env: env, day: day, id: "review", model: Self.autoReview, creator: creator)
        let cache = try Self.scannedCache(day: day, env: env)
        let entry = try #require(Self.report(cache, day: day).data.first)

        #expect(cache.files.values.first?.codexSession?.hasCreatorAccount != true)
        #expect(entry.unpricedRequestCount == 2)
        #expect(entry.costUSD == nil)
        #expect(entry.totalTokens == 300_000)
    }

    @Test
    func `a priced model and free auto review on one day keep the exact priced subtotal`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        _ = try Self.writeSession(env: env, day: day, id: "priced", model: "gpt-5.4", inputs: [100_000])
        _ = try Self.writeSession(
            env: env, day: day, id: "review", model: Self.autoReview, inputs: [50000], creator: "acct-fixture")
        let entry = try #require(Self.report(Self.scannedCache(day: day, env: env), day: day).data.first)
        let priced = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.4", inputTokens: 100_000, cachedInputTokens: 0, outputTokens: 0))
        let review = try #require(entry.modelBreakdowns?.first { $0.modelName == Self.autoReview })

        #expect(abs((entry.costUSD ?? -1) - priced) < 1e-9)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.unmeteredRequestCount == nil)
        #expect(entry.coverageCounts.unpriced == 0)
        #expect(entry.totalTokens == 150_000)
        #expect(review.totalTokens == 50000)
        #expect(review.costUSD == 0)
    }

    /// Only the ChatGPT session's requests are free; the API-key session's requests stay unpriced.
    @Test
    func `ChatGPT and API key auto review on one day split by session`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        _ = try Self.writeSession(env: env, day: day, id: "chatgpt", model: Self.autoReview, creator: "acct-fixture")
        _ = try Self.writeSession(env: env, day: day, id: "apikey", model: Self.autoReview, inputs: [70000])
        let entry = try #require(Self.report(Self.scannedCache(day: day, env: env), day: day).data.first)

        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.pricedRequestCount == 2)
        #expect(entry.unmeteredRequestCount == nil)
        #expect(entry.costUSD == 0)
        #expect(entry.totalTokens == 370_000)
    }

    @Test
    func `another unpriced model in a ChatGPT session after the cutoff stays unpriced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        _ = try Self.writeSession(
            env: env, day: day, id: "other", model: "codex-fictional-reviewer", creator: "acct-fixture")
        let entry = try #require(Self.report(Self.scannedCache(day: day, env: env), day: day).data.first)

        #expect(entry.unpricedRequestCount == 2)
        #expect(entry.costUSD == nil)
    }

    /// Day keys follow the local calendar, so the cutoff uses each request's instant.
    @Test
    func `requests straddling the cutoff instant on one day split between unpriced and priced`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        let rows = [
            Self.row(index: 0, timestampUnixMs: cutoff - 1, input: 1000),
            Self.row(index: 1, timestampUnixMs: cutoff, input: 2000),
        ]
        let report = Self.report(rows: rows, hasCreatorAccount: true)
        let entry = try #require(report.data.first)

        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unmeteredRequestCount == nil)
        #expect(entry.costUSD == 0)
        #expect(entry.totalTokens == 3020)
        let slices = report.quotaSlices
        #expect(slices.count == 2)
        #expect(slices.first?.costIsComplete == false)
        #expect(slices.last?.costUSD == 0)
        #expect(slices.last?.costIsComplete == true)
    }

    @Test
    func `a cached file without the creator flag stays unpriced`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        let entry = try #require(Self.report(
            rows: [Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000)],
            hasCreatorAccount: nil).data.first)

        #expect(entry.unpricedRequestCount == 1)
    }

    /// A models.dev or bundled list price for the model must not charge free requests.
    @Test
    func `free auto review ignores a catalog price for the model`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        let report = Self.report(
            rows: [Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000)],
            hasCreatorAccount: true,
            catalog: Self.catalog(pricing: Self.autoReview))
        let entry = try #require(report.data.first)

        #expect(entry.costUSD == 0)
        #expect(entry.unpricedRequestCount == nil)
    }

    /// An explicit custom rate keeps its precedence over dated pricing changes, the waiver included.
    @Test(arguments: [Self.autoReview, "openai/\(Self.autoReview)"])
    func `free auto review uses an explicit custom rate for the model`(key: String) throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        let report = Self.report(
            rows: [Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000)],
            hasCreatorAccount: true,
            catalog: Self.catalog(pricing: Self.autoReview),
            customPricing: Self.overlay(key: key, rates: #"{"input":5,"output":10}"#))
        let entry = try #require(report.data.first)
        let breakdown = try #require(entry.modelBreakdowns?.first { $0.modelName == Self.autoReview })
        // 1,000 input tokens at $5/M plus 10 output tokens at $10/M.
        let expected = 0.0051

        #expect(abs((entry.costUSD ?? -1) - expected) < 1e-12)
        #expect(abs((breakdown.costUSD ?? -1) - expected) < 1e-12)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.coverageCounts.priced == 1)
        #expect(entry.coverageCounts.unpriced == 0)
        let hourlyComplete = report.hourly.allSatisfy(\.costIsComplete)
        let slicesComplete = report.quotaSlices.allSatisfy(\.costIsComplete)
        #expect(report.hourly.count == 1)
        #expect(abs((report.hourly.first?.costUSD ?? -1) - expected) < 1e-12)
        #expect(hourlyComplete)
        #expect(report.quotaSlices.count == 1)
        #expect(abs((report.quotaSlices.first?.costUSD ?? -1) - expected) < 1e-12)
        #expect(slicesComplete)
    }

    /// A custom row missing a consumed token class is unpriced, as for any model; it is neither $0 nor a catalog price.
    @Test
    func `a partial custom rate leaves free auto review unpriced`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        let report = Self.report(
            rows: [Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000)],
            hasCreatorAccount: true,
            catalog: Self.catalog(pricing: Self.autoReview),
            customPricing: Self.overlay(key: Self.autoReview, rates: #"{"input":5}"#))
        let entry = try #require(report.data.first)

        #expect(entry.costUSD == nil)
        #expect(entry.unpricedRequestCount == 1)
        #expect(report.quotaSlices.allSatisfy { $0.costUSD == nil && !$0.costIsComplete })
    }

    @Test
    func `a free priority request reports a zero priority split`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        let report = Self.report(
            rows: [Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000, pricingMode: "priority")],
            hasCreatorAccount: true)
        let entry = try #require(report.data.first)
        let breakdown = try #require(entry.modelBreakdowns?.first)

        #expect(entry.costUSD == 0)
        #expect(entry.unpricedRequestCount == nil)
        #expect(breakdown.priorityCostUSD == 0)
        #expect(breakdown.priorityTokens == 1010)
        #expect(breakdown.standardCostUSD == nil)
        #expect(report.quotaSlices.first?.costUSD == 0)
        #expect(report.quotaSlices.first?.costIsComplete == true)
    }

    /// A retained authoritative amount wins over the free classification.
    @Test
    func `an authoritative amount on an eligible row is kept`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        var row = Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000)
        row.knownCostNanos = 5_000_000
        let report = Self.report(rows: [row], hasCreatorAccount: true)
        let entry = try #require(report.data.first)

        #expect(abs((entry.costUSD ?? -1) - 0.005) < 1e-12)
        #expect(entry.unpricedRequestCount == nil)
        #expect(abs((report.quotaSlices.first?.costUSD ?? -1) - 0.005) < 1e-12)
    }

    /// Hourly and quota slices claim $0 only where the day entry honors the free classification.
    @Test
    func `slices stay incomplete when the rows do not cover the day`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        // A row without a stable event index cannot prove the group's request boundaries.
        let unstable = CostUsageScanner.CodexUsageRow(
            day: Self.cutoffDay,
            model: Self.autoReview,
            turnID: "turn-0",
            eventIndex: nil,
            timestampUnixMs: cutoff + 1000,
            input: 1000,
            cached: 0,
            output: 10,
            pricingModel: Self.autoReview,
            pricingMode: "standard")
        let report = Self.report(rows: [unstable], hasCreatorAccount: true)
        let entry = try #require(report.data.first)

        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.costUSD == nil)
        #expect(!report.quotaSlices.isEmpty)
        #expect(report.quotaSlices.allSatisfy { !$0.costIsComplete })
        #expect(report.hourly.allSatisfy { !$0.costIsComplete })
    }

    /// When the rows don't account for the billed tokens, the group stays unpriced: neither the
    /// day's aggregate fallback nor an hourly slice may apply a list price to a free request.
    /// In the file, reconciliation drops the rows; beyond it, the rows stay but undercount the day.
    @Test(arguments: [true, false])
    func `uncovered free auto review stays unpriced despite a catalog price`(extraTokensInFile: Bool) throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        let report = Self.report(
            rows: [Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000)],
            hasCreatorAccount: true,
            catalog: Self.catalog(pricing: Self.autoReview),
            extraBilledInput: 500,
            extraBilledInputInFile: extraTokensInFile)
        let entry = try #require(report.data.first)

        #expect(entry.totalTokens == 1510)
        #expect(entry.costUSD == nil)
        #expect(entry.unpricedRequestCount == 1)
        #expect(report.quotaSlices.isEmpty == extraTokensInFile)
        #expect(report.quotaSlices.allSatisfy { $0.costUSD == nil && !$0.costIsComplete })
        #expect(report.hourly.allSatisfy { $0.costUSD == nil && !$0.costIsComplete })
    }

    /// With an explicit custom rate, an uncovered group prices exactly like the same rows from an API-key
    /// session: the custom rate applies as it does to any custom-priced model, and the catalog never does.
    @Test(arguments: [true, false])
    func `uncovered auto review with a custom rate prices like an ineligible session`(extraTokensInFile: Bool) throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        func report(hasCreatorAccount: Bool, rates: String?) -> CostUsageDailyReport {
            Self.report(
                rows: [Self.row(index: 0, timestampUnixMs: cutoff + 1000, input: 1000)],
                hasCreatorAccount: hasCreatorAccount,
                catalog: Self.catalog(pricing: Self.autoReview),
                customPricing: rates.map { Self.overlay(key: Self.autoReview, rates: $0) } ?? .empty,
                extraBilledInput: 500,
                extraBilledInputInFile: extraTokensInFile)
        }
        let custom = #"{"input":5,"output":10}"#
        let eligible = report(hasCreatorAccount: true, rates: custom)
        let ineligible = report(hasCreatorAccount: false, rates: custom)
        let entry = try #require(eligible.data.first)

        #expect(eligible.data == ineligible.data)
        #expect(eligible.hourly == ineligible.hourly)
        #expect(eligible.quotaSlices == ineligible.quotaSlices)
        #expect(entry.totalTokens == 1510)
        // The day's 1,500 input and 10 output tokens at the custom rate; the catalog rate would give $0.00152.
        #expect(abs((entry.costUSD ?? -1) - 0.0076) < 1e-12)
        #expect(entry.unpricedRequestCount == nil)
    }

    /// A free request without tokens costs nothing even where the day entry doesn't honor free requests.
    @Test
    func `a free request without tokens keeps its slice complete beside a priced request`() throws {
        let cutoff = CostUsageScanner.CodexIncludedUsage.autoReviewIncludedSinceUnixMs
        let empty = CostUsageScanner.CodexUsageRow(
            day: Self.cutoffDay,
            model: Self.autoReview,
            turnID: "turn-1",
            eventIndex: 1,
            timestampUnixMs: cutoff + 1000,
            input: 0,
            cached: 0,
            output: 0,
            pricingModel: Self.autoReview,
            pricingMode: "standard")
        let report = Self.report(
            rows: [Self.row(index: 0, timestampUnixMs: cutoff - 1000, input: 1000), empty],
            hasCreatorAccount: true,
            catalog: Self.catalog(pricing: Self.autoReview))
        let entry = try #require(report.data.first)

        #expect((entry.costUSD ?? 0) > 0)
        #expect(entry.unpricedRequestCount == nil)
        #expect(report.quotaSlices.count == 2)
        let allSlicesComplete = report.quotaSlices.allSatisfy(\.costIsComplete)
        #expect(allSlicesComplete)
    }

    /// Caches written before the creator flag existed reparse once and then classify the requests.
    @Test
    func `stale parser caches pick up the creator flag on the next scan`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        _ = try Self.writeSession(env: env, day: day, id: "review", model: Self.autoReview, creator: "acct-fixture")
        var legacy = try Self.scannedCache(day: day, env: env)
        for path in Array(legacy.files.keys) {
            legacy.files[path]?.codexSession?.hasCreatorAccount = nil
            legacy.files[path]?.codexParserRevision = CostUsageFileUsage.currentCodexParserRevision - 1
        }
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy)
        #expect(Self.report(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot), day: day)
            .data.first?.unpricedRequestCount == 2)

        let migrated = try Self.scannedCache(day: day, env: env)
        let entry = try #require(Self.report(migrated, day: day).data.first)

        let allFilesUpgraded = migrated.files.values.allSatisfy(\.hasCurrentCodexParser)
        #expect(allFilesUpgraded)
        #expect(migrated.files.values.first?.codexSession?.hasCreatorAccount == true)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.costUSD == 0)
        #expect(entry.totalTokens == 300_000)
    }

    /// Only the leaf session_meta decides. An appended same-session meta must not change the result,
    /// and an incremental parse must agree with a full parse of the same bytes.
    @Test
    func `an appended session meta cannot grant the creator flag`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        let file = try Self.writeSession(env: env, day: day, id: "review", model: Self.autoReview)
        _ = try Self.scannedCache(day: day, env: env)
        let timestamp = env.isoString(for: day.addingTimeInterval(60))
        let appended = try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["id": "review", "creator_account_id": "acct-fixture"],
            ],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count",
                "info": ["last_token_usage": ["input_tokens": 40000, "cached_input_tokens": 0, "output_tokens": 0]],
            ]],
        ])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let incremental = try Self.scannedCache(day: day, env: env)
        let fullRoot = env.root.appendingPathComponent("full-cache", isDirectory: true)
        let full = try Self.scannedCache(day: day, env: env, cacheRoot: fullRoot)
        let incrementalEntry = try #require(Self.report(incremental, day: day).data.first)
        let fullEntry = try #require(Self.report(full, day: day).data.first)

        #expect(incremental.files.values.first?.codexSession?.hasCreatorAccount == false)
        #expect(full.files.values.first?.codexSession?.hasCreatorAccount == false)
        #expect(incrementalEntry == fullEntry)
        #expect(incrementalEntry.unpricedRequestCount == 3)
        #expect(incrementalEntry.costUSD == nil)
    }

    /// Two files of one session: cache reuse filters duplicate requests but must keep the leaf flag.
    @Test
    func `refreshes over files sharing a session keep identical results`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 8)
        for (offset, inputs, filename) in [
            (0.0, [100_000, 200_000], "shared-a.jsonl"),
            (60.0, [30000], "shared-b.jsonl"),
        ] {
            _ = try Self.writeSession(
                env: env,
                day: day.addingTimeInterval(offset),
                id: "shared",
                model: Self.autoReview,
                inputs: inputs,
                creator: "acct-fixture",
                filename: filename)
        }
        let first = try Self.scannedCache(day: day, env: env)
        let second = try Self.scannedCache(day: day.addingTimeInterval(1), env: env)
        let third = try Self.scannedCache(day: day.addingTimeInterval(2), env: env)
        let firstEntry = try #require(Self.report(first, day: day).data.first)

        #expect(firstEntry.unpricedRequestCount == nil)
        #expect(firstEntry.costUSD == 0)
        #expect(Self.report(second, day: day).data == Self.report(first, day: day).data)
        #expect(Self.report(third, day: day).data == Self.report(first, day: day).data)
        let flags = third.files.values.filter { !($0.codexRows ?? []).isEmpty }
            .map { $0.codexSession?.hasCreatorAccount }
        #expect(!flags.isEmpty)
        #expect(flags.allSatisfy { $0 == true })
    }

    // MARK: - Fixtures

    private static func writeSession(
        env: CostUsageTestEnvironment,
        day: Date,
        id: String,
        model: String,
        inputs: [Int] = [100_000, 200_000],
        creator: String? = nil,
        filename: String? = nil) throws -> URL
    {
        let timestamp = env.isoString(for: day)
        var meta: [String: Any] = ["id": id]
        if let creator { meta["creator_account_id"] = creator }
        var records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": meta],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": model]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "\(id)-turn"]],
        ]
        for input in inputs {
            records.append(["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count",
                "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0]],
            ]])
        }
        return try env.writeCodexSessionFile(
            day: day, filename: filename ?? "\(id).jsonl", contents: env.jsonl(records))
    }

    static func scannedCache(
        day: Date,
        env: CostUsageTestEnvironment,
        cacheRoot: URL? = nil) throws -> CostUsageCache
    {
        let cacheRoot = cacheRoot ?? env.cacheRoot
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        return CostUsageStoreAccess.read(cacheRoot: cacheRoot)
    }

    static func report(_ cache: CostUsageCache, day: Date) -> CostUsageDailyReport {
        CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: .init(since: day, until: day),
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
    }

    private static func currentQuotaWeek(_ report: CostUsageDailyReport, day: Date) -> CostUsageQuotaWeek? {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: report.summary?.totalTokens,
            sessionCostUSD: report.summary?.totalCostUSD,
            last30DaysTokens: report.summary?.totalTokens,
            last30DaysCostUSD: report.summary?.totalCostUSD,
            daily: report.data,
            hourly: report.hourly,
            quotaSlices: report.quotaSlices,
            updatedAt: day.addingTimeInterval(3600))
        return snapshot.quotaWeekSummaries(
            resetAt: day.addingTimeInterval(3 * 86400),
            now: day.addingTimeInterval(3600)).first
    }

    private static let cutoffDay = "2026-10-06"
    private static let cutoffNoon = Date(timeIntervalSince1970: 1_791_313_200) // 2026-10-06 12:00 PDT.
    private static var pacific: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private static func row(
        index: Int,
        timestampUnixMs: Int64,
        input: Int,
        pricingMode: String = "standard") -> CostUsageScanner.CodexUsageRow
    {
        CostUsageScanner.CodexUsageRow(
            day: self.cutoffDay,
            model: self.autoReview,
            turnID: "turn-\(index)",
            eventIndex: index,
            timestampUnixMs: timestampUnixMs,
            input: input,
            cached: 0,
            output: 10,
            pricingModel: self.autoReview,
            pricingMode: pricingMode)
    }

    private static func session(
        id: String,
        hasCreatorAccount: Bool?,
        startedAtUnixMs: Int64? = nil) -> CostUsageCodexSessionMetadata
    {
        CostUsageCodexSessionMetadata(
            sessionId: id,
            forkedFromId: nil,
            cwd: nil,
            title: nil,
            startedAtUnixMs: startedAtUnixMs,
            latestActivityUnixMs: startedAtUnixMs,
            hasCreatorAccount: hasCreatorAccount)
    }

    private static func report(
        rows: [CostUsageScanner.CodexUsageRow],
        hasCreatorAccount: Bool?,
        catalog: ModelsDevCatalog = ModelsDevCatalog(providers: [:]),
        customPricing: CostUsageCustomPricing = .empty,
        extraFiles: [String: CostUsageFileUsage] = [:],
        extraBilledInput: Int = 0,
        extraBilledInputInFile: Bool = false) -> CostUsageDailyReport
    {
        let input = rows.reduce(0) { $0 + $1.input }
        let output = rows.reduce(0) { $0 + $1.output }
        let fileInput = extraBilledInputInFile ? input + extraBilledInput : input
        var usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [self.cutoffDay: [self.autoReview: [fileInput, 0, output]]],
            parsedBytes: 1,
            codexRows: rows,
            codexScanComplete: true)
        usage.codexSession = self.session(id: "review", hasCreatorAccount: hasCreatorAccount)
        var cache = CostUsageCache()
        cache.files = ["/auto-review.jsonl": usage].merging(extraFiles) { current, _ in current }
        cache.days = [self.cutoffDay: [self.autoReview: [input + extraBilledInput, 0, output]]]
        return CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: .init(since: self.cutoffNoon, until: self.cutoffNoon, calendar: self.pacific),
            modelsDevCatalog: catalog,
            customPricing: customPricing)
    }

    private static func overlay(key: String, rates: String) -> CostUsageCustomPricing {
        CostUsageCustomPricing.parse(Data(#"{"\#(key)":\#(rates)}"#.utf8))
    }

    private static func catalog(pricing model: String) -> ModelsDevCatalog {
        ModelsDevCatalog(providers: [
            "openai": ModelsDevProvider(
                id: "openai",
                name: "OpenAI",
                models: [model: ModelsDevModel(
                    id: model,
                    name: nil,
                    cost: ModelsDevCost(input: 1, output: 2),
                    limit: nil)]),
        ])
    }
}
