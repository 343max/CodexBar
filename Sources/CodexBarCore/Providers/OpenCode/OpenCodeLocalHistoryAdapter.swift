import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// The OpenCode local history adapter: reads the machine-local `opencode.db` for
/// assistant records whose provider is exactly `openai` and feeds them into the existing
/// `CostUsageStore` as **one registered source file** — the shape approved in #4752.
///
/// - Decodes turns inside short read-only source transactions and commits rows, per-file
///   day aggregates, global deltas, and its checkpoint atomically through the store's own
///   writer (`applyOpenCodeLocalHistoryPass`). There is no second writable history cache.
/// - Its progress rides in `scan_state.resumePayload` as the typed, versioned
///   `OpenCodeSourceCheckpoint`; native Codex records decode exactly as before (the
///   discriminator defaults them to native).
/// - Publication stays windowed and source-I/O-free: reports merge this file's
///   `file_day_aggregates` bounded by the reporting window via `windowedAggregates`.
///
/// Cursor contract (the three #4744 regressions, designed out):
/// 1. Budgets count **raw rows read**, never successful decodes; exhaustion is a
///    raw-lookahead verdict (`budget + 1`), so an invalid row cannot make an unfinished
///    range look complete.
/// 2. Boundaries are **exclusive** and pinned only by the SELECT that consumed the rows —
///    never a later `MAX(rowid)` from a different snapshot. An append racing a pass stays
///    eligible on the next pass.
/// 3. A message with more parts than one pass's budget checkpoints a strict
///    `(messageRowid, partRowid)` continuation and resumes mid-message; the continuation
///    persists atomically with the rows it produced.
///
/// Source contract (unchanged from the #3273 reviews):
/// - Usage metadata only, `SQLITE_OPEN_READONLY`. Prompts, responses, tool output and
///   `auth.json` are never read; rows are never attributed to an account.
/// - Exact `providerID == "openai"` assistant records. Valid `step-finish` parts each
///   contribute (part-level identities); message-level totals fill in only when a message
///   has no valid part, mirroring the Go reader's precedence.
/// - OpenCode v2 `session_message` duplicates legacy `message` rows under the same IDs:
///   a v2 row contributes only when the legacy row is not itself usable (the usable-legacy
///   projection from #4587).
/// - Recorded cost surfaces as-is in `authoritative_cost_nanos`, including `$0` for
///   OpenCode subscription usage (#4752 point 3: presence is the signal). Tokens are
///   recorded dimensions only.
enum OpenCodeLocalHistoryAdapter {
    /// PRIMARY-key friendly, idempotent identity for one decoded source row inside
    /// `usage_rows` `row_index` (`file_id` is supplied by the store). FNV-1a 64-bit over
    /// `"<namespace>:<sourceID>"`: stable across re-evaluations, migrations and restarts,
    /// and immune to rowid collisions across the three source tables (#4752 point 1).
    static func rowIdentity(namespace: Namespace, sourceID: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (namespace.rawValue + ":" + sourceID).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash & 0x7fff_ffff_ffff_ffff)
    }

    /// The identity namespace discriminating row keys across source tables.
    enum Namespace: String, Codable, Sendable {
        case message
        case part
        case session_message
    }

    /// One decoded assistant turn; the `usage_rows` payload.
    struct Turn: Codable, Equatable, Sendable {
        var namespace: String
        var sourceID: String
        var createdMs: Int64
        var costUSD: Double
        var modelID: String
        var totalTokens: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var reasoningTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
    }

    // MARK: - Source resolution (#3273 single-database contract, mirroring upstream)

    /// Resolves the XDG data root the way OpenCode's `xdg-basedir` dependency does: an
    /// absolute `XDG_DATA_HOME` wins; relative or missing values fall back to
    /// `~/.local/share`.
    static func xdgDataRoot(homeDirectory: URL, environment: [String: String]) -> URL {
        if let raw = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("/")
        {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
    }

    /// Resolves the single database OpenCode itself would use, mirroring upstream
    /// `database.path()`: `OPENCODE_DB` selects exactly one database (`:memory:` is
    /// unreachable for an on-disk reader; absolute paths win as-is; relative names resolve
    /// inside the data directory) and is never substituted with another database. Without
    /// an explicit selection, the plain `opencode.db` is the contract's selection;
    /// non-release channel databases stay reachable through `OPENCODE_DB`, exactly like
    /// pointing OpenCode itself at them.
    static func resolvedDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        let dataDirectory = Self.xdgDataRoot(homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent("opencode", isDirectory: true)
        if let override = environment["OPENCODE_DB"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            if override == ":memory:" {
                return dataDirectory.appendingPathComponent("unreachable-memory-db", isDirectory: false)
            }
            if override.hasPrefix("/") {
                return URL(fileURLWithPath: override)
            }
            return dataDirectory.appendingPathComponent(override, isDirectory: false)
        }
        return dataDirectory.appendingPathComponent("opencode.db", isDirectory: false)
    }

    // MARK: - Fingerprint

    /// The identity capture a pass brackets its reads with: the main database plus its
    /// WAL sidecar, matching upstream's Go reader, so WAL appends invalidate progress
    /// without waiting for a checkpoint.
    static func fingerprint(for url: URL) -> OpenCodeSourceCheckpoint.Fingerprint? {
        let url = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return nil }
        let walAttrs = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        return OpenCodeSourceCheckpoint.Fingerprint(
            path: url.path,
            size: size,
            modifiedUnixMs: Int64(mtime * 1000),
            walSize: (walAttrs?[.size] as? NSNumber)?.int64Value,
            walModifiedUnixMs: (walAttrs?[.modificationDate] as? Date)
                .map { Int64($0.timeIntervalSince1970 * 1000) })
    }
}

#if canImport(SQLite3) || canImport(CSQLite3)
extension OpenCodeLocalHistoryAdapter {
    // MARK: - Pass driver

    /// The registration path for the source in `files.path`: the resolved database path
    /// itself (source discrimination travels in the typed state, not a filename
    /// heuristic, per #4752 point 2).
    static func registeredPath(for databaseURL: URL) -> String {
        databaseURL.resolvingSymlinksInPath().path
    }

    enum SkipReason: Equatable, Sendable {
        case unreadable
        case unchanged
        case movedUnderRead
        case staleBaseline
    }

    enum PassOutcome: Equatable, Sendable {
        case applied(PassSummary)
        case skipped(SkipReason)
    }

    struct PassSummary: Equatable, Sendable {
        var rawRowsRead: Int
        var decodedTurns: Int
        var wipe: Bool
        var complete: Bool
    }

    /// One bounded adapter pass for the registered source — the sibling module driven by
    /// the scanner (#4752). All source reads happen in a short read-only transaction; the
    /// destination write commits atomically with its checkpoint under the store's writer
    /// lock, and repeated passes are idempotent by construction.
    static func runPass(
        databaseURL: URL,
        store: CostUsageStore,
        rowBudget: Int = 100_000,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) async throws -> PassOutcome?
    {
        let path = Self.registeredPath(for: databaseURL)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Read the durable baseline; a missing record means first contact and the
        // expected baseline is "no record at all".
        let stored = await store.withDatabase(default: CostUsageStoreFile?.none) { database in
            try CostUsageStore.readFiles(database).first { $0.path == path }
        }
        let baselinePayload = stored?.scanState.resumePayload
        let baselineCheckpoint = OpenCodeSourceCheckpoint.decode(baselinePayload)

        guard let before = Self.fingerprint(for: databaseURL) else {
            return .skipped(.unreadable)
        }
        // An unchanged fingerprint over a COMPLETE committed checkpoint short-circuits
        // the pass: publication then proceeds entirely from the store. An incomplete
        // checkpoint (unfinished windows, a pending oversized message) converges first —
        // this is how budgeted passes ever finish converging when nothing changed.
        if let checkpoint = baselineCheckpoint,
           checkpoint.fingerprint == before,
           checkpoint.tables.message.low == 0,
           checkpoint.tables.sessionMessage.low == 0,
           checkpoint.pendingPartContinuation == nil,
           checkpoint.reconciliation == nil
        {
            return .skipped(.unchanged)
        }

        let decode = try Self.decodePass(
            databaseURL: databaseURL,
            registeredPath: path,
            baseline: baselineCheckpoint,
            fingerprint: before,
            rowBudget: rowBudget,
            checkCancellation: checkCancellation)

        // The fingerprint must bracket the reads: a source that moved mid-pass makes the
        // pass unverifiable above the change point. Boundaries only advance to rows the
        // reads themselves pinned, so a retry next pass is always safe.
        guard before == Self.fingerprint(for: databaseURL) else {
            return .skipped(.movedUnderRead)
        }

        var state = CostUsageStoreScanState(isComplete: decode.complete && !decode.hasPendingContinuation)
        state.source = .opencodeLocalHistory
        state.resumePayload = try JSONEncoder().encode(decode.checkpoint)
        let file = CostUsageStoreFile(
            path: path,
            inode: stored?.inode,
            mtimeUnixMs: before.modifiedUnixMs,
            size: before.size,
            parsedBytes: nil,
            anchor: nil,
            scanState: state,
            sessionID: nil,
            coverageSinceDay: decode.aggregates.min { $0.day < $1.day }?.day ?? stored?.coverageSinceDay,
            coverageUntilDay: decode.aggregates.max { $0.day < $1.day }?.day ?? stored?.coverageUntilDay,
            updatedAtUnixMs: Int64(Date().timeIntervalSince1970 * 1000))

        // 5. Resolve OLD contributions for mutation swaps before committing (#4752
        //    point 4). Fetched payloads decode into the previous emitted turn, so the
        //    store sees exact signed deltas. The same reads also recover the previously
        //    stored file-level bucket values — per-file aggregates are absolute, not
        //    deltas — so an append or swap cannot erase prior passes' contribution.
        let touchedIndices = Array(Set(decode.replacementRowIndices + decode.deleteRowIndices))
        var oldByBucket: [String: CostUsageStoreDayAggregate] = [:]
        if !touchedIndices.isEmpty {
            let oldPayloads = await store.withDatabase(default: [Int64: Data]()) { database in
                try CostUsageStore.readUsagePayloads(database, path: path, rowIndices: touchedIndices)
            }
            for payload in oldPayloads.values {
                guard let oldTurn = try? JSONDecoder().decode(Turn.self, from: payload) else { continue }
                guard oldTurn.createdMs > 0 else { continue }
                let day = Self.dayKey(fromUnixMs: oldTurn.createdMs)
                let key = day + "␟" + oldTurn.modelID
                var negated = oldByBucket[key] ?? CostUsageStoreDayAggregate.zero(
                    day: day, model: oldTurn.modelID)
                negated.inputTokens -= Int64(oldTurn.inputTokens ?? 0)
                negated.cachedTokens -= Int64((oldTurn.cacheReadTokens ?? 0) + (oldTurn.cacheCreationTokens ?? 0))
                negated.outputTokens -= Int64(oldTurn.outputTokens ?? 0)
                negated.reasoningTokens -= Int64(oldTurn.reasoningTokens ?? 0)
                negated.requestCount -= 1
                negated.authoritativeCostNanos -= Int64((oldTurn.costUSD * 1e9).rounded())
                negated.standardInputTokens -= Int64(oldTurn.inputTokens ?? 0)
                negated.standardCachedTokens -= Int64((oldTurn.cacheReadTokens ?? 0) + (oldTurn.cacheCreationTokens ?? 0))
                negated.standardOutputTokens -= Int64(oldTurn.outputTokens ?? 0)
                negated.standardTokens -= Int64((oldTurn.inputTokens ?? 0)
                    + ((oldTurn.cacheReadTokens ?? 0) + (oldTurn.cacheCreationTokens ?? 0))
                    + (oldTurn.outputTokens ?? 0))
                oldByBucket[key] = negated
            }
        }

        let storedAggregates = await store.withDatabase(
            default: [CostUsageStoreFileDayAggregate]())
        { database in
            try CostUsageStore.readFileDayAggregates(database, path: path)
        }
        var absByBucket: [String: CostUsageStoreDayAggregate] = [:]
        for storedAggregate in storedAggregates {
            absByBucket[storedAggregate.aggregate.day + "␟" + storedAggregate.aggregate.model] = storedAggregate.aggregate
        }
        // Contribution additions (append + re-evaluated emissions).
        for contribution in decode.aggregates {
            let key = contribution.day + "␟" + contribution.model
            var absolute = absByBucket[key]
                ?? CostUsageStoreDayAggregate.zero(day: contribution.day, model: contribution.model)
            absolute.inputTokens += contribution.inputTokens
            absolute.cachedTokens += contribution.cachedTokens
            absolute.outputTokens += contribution.outputTokens
            absolute.reasoningTokens += contribution.reasoningTokens
            absolute.requestCount += contribution.requestCount
            absolute.authoritativeCostNanos += contribution.authoritativeCostNanos
            absolute.standardInputTokens += contribution.standardInputTokens
            absolute.standardCachedTokens += contribution.standardCachedTokens
            absolute.standardOutputTokens += contribution.standardOutputTokens
            absolute.priorityInputTokens += contribution.priorityInputTokens
            absolute.priorityCachedTokens += contribution.priorityCachedTokens
            absolute.priorityOutputTokens += contribution.priorityOutputTokens
            absolute.standardTokens += contribution.standardTokens
            absolute.priorityTokens += contribution.priorityTokens
            absByBucket[key] = absolute
        }
        // Signed subtractions from superseded payloads.
        for (key, negated) in oldByBucket {
            var absolute = absByBucket[key]
                ?? CostUsageStoreDayAggregate.zero(day: negated.day, model: negated.model)
            absolute.inputTokens += negated.inputTokens
            absolute.cachedTokens += negated.cachedTokens
            absolute.outputTokens += negated.outputTokens
            absolute.reasoningTokens += negated.reasoningTokens
            absolute.requestCount += negated.requestCount
            absolute.authoritativeCostNanos += negated.authoritativeCostNanos
            absolute.standardInputTokens += negated.standardInputTokens
            absolute.standardCachedTokens += negated.standardCachedTokens
            absolute.standardOutputTokens += negated.standardOutputTokens
            absolute.priorityInputTokens += negated.priorityInputTokens
            absolute.priorityCachedTokens += negated.priorityCachedTokens
            absolute.priorityOutputTokens += negated.priorityOutputTokens
            absolute.standardTokens += negated.standardTokens
            absolute.priorityTokens += negated.priorityTokens
            absByBucket[key] = absolute
        }
        // Only buckets this pass actually touched are upserted; untouched file buckets
        // carry over unaffected (#4752 performance contract).
        let touchedKeys = Set(decode.aggregates.map { $0.day + "␟" + $0.model })
            .union(oldByBucket.keys)
        let fileAggregates = absByBucket.filter { touchedKeys.contains($0.key) }
            .map(\.value).sorted { ($0.day, $0.model) < ($1.day, $1.model) }

        let accepted = await store.applyOpenCodeLocalHistoryPass(
            file: file,
            expectedBaselineResumePayload: baselinePayload,
            wipe: decode.wipe,
            usageRows: decode.usageRows,
            fileAggregates: fileAggregates,
            globalDeltas: decode.globalDeltas,
            reevalDeleteRowIndices: decode.deleteRowIndices,
            reevalOldDeltas: Array(oldByBucket.values))
        guard accepted else { return .skipped(.staleBaseline) }
        return .applied(PassSummary(
            rawRowsRead: decode.rawRowsRead,
            decodedTurns: decode.usageRows.count,
            wipe: decode.wipe,
            complete: state.isComplete))
    }

    // MARK: - Read-side: bounded publication

    /// Converts this file's windowed aggregates into daily-report entries (#4752 point
    /// 2–3): costs surface the price the source itself recorded — including `$0` for
    /// OpenCode subscription usage, where presence is the signal — and every model
    /// breakdown carries `sourceRecorded` so the merge can never fold them with a
    /// same-named priced estimate.
    static func reportEntries(
        from aggregates: [CostUsageStoreFileDayAggregate]) -> [CostUsageDailyReport.Entry]
    {
        var byDay: [String: [CostUsageStoreFileDayAggregate]] = [:]
        for aggregate in aggregates {
            byDay[aggregate.aggregate.day, default: []].append(aggregate)
        }
        return byDay.keys.sorted().map { day in
            let rows = byDay[day, default: []]
            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            var input = 0
            var cached = 0
            var output = 0
            var reasoning = 0
            var requests: Int64 = 0
            var costNanos: Int64 = 0
            for row in rows {
                let aggregate = row.aggregate
                input += Int(aggregate.inputTokens)
                cached += Int(aggregate.cachedTokens)
                output += Int(aggregate.outputTokens)
                reasoning += Int(aggregate.reasoningTokens)
                requests += aggregate.requestCount
                costNanos += aggregate.authoritativeCostNanos
                breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: aggregate.model,
                    costUSD: Double(aggregate.authoritativeCostNanos) / 1e9,
                    totalTokens: Int(aggregate.inputTokens + aggregate.cachedTokens
                        + aggregate.outputTokens + aggregate.reasoningTokens),
                    requestCount: Int(aggregate.requestCount),
                    inputTokens: Int(aggregate.inputTokens),
                    outputTokens: Int(aggregate.outputTokens),
                    reasoningTokens: Int(aggregate.reasoningTokens),
                    sourceRecorded: true))
            }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cached,
                cacheCreationTokens: 0,
                reasoningTokens: reasoning,
                totalTokens: input + cached + output + reasoning,
                requestCount: Int(requests),
                costUSD: Double(costNanos) / 1e9,
                modelsUsed: breakdowns.isEmpty ? nil : breakdowns.map(\.modelName).sorted(),
                modelBreakdowns: breakdowns.isEmpty
                    ? nil
                    : CostUsageDailyReport.sortedModelBreakdowns(breakdowns),
                unpricedRequestCount: nil,
                unmeteredRequestCount: nil,
                estimatedRequestCount: nil,
                pricedRequestCount: Int(requests))
        }
    }


    /// This file's day aggregates inside the reporting window — the source summary the
    /// read view carries (#4752 point 2). Produced entirely from the store (no source
    /// I/O), bounded by the window, and carrying `file_id` provenance by construction.
    static func windowedAggregates(
        store: CostUsageStore,
        path: String,
        sinceDay: String,
        untilDay: String) async -> [CostUsageStoreFileDayAggregate]
    {
        await store.withDatabase(default: []) { database in
            try CostUsageStore.readFileDayAggregates(
                database, path: path, sinceDay: sinceDay, untilDay: untilDay)
        }
    }
}

// MARK: - Decoding internals

extension OpenCodeLocalHistoryAdapter {
    struct DecodeResult {
        var checkpoint: OpenCodeSourceCheckpoint
        var complete: Bool
        var hasPendingContinuation: Bool
        var wipe: Bool
        var rawRowsRead: Int
        var usageRows: [CostUsageStoreUsageRow]
        var aggregates: [CostUsageStoreDayAggregate]
        var globalDeltas: [CostUsageStoreDayAggregate]
        /// Mutation swaps: row indices whose previous contribution is replaced by the
        /// re-evaluated content also present in `usageRows`, or outright deleted
        /// (a session row that became excluded). The pass resolves the stored negative
        /// contributions before committing (#4752 point 4).
        var replacementRowIndices: [Int64]
        var deleteRowIndices: [Int64]
    }

    /// Decodes at most `rowBudget` raw source rows beyond the baseline checkpoint inside
    /// one short read-only source transaction. The returned checkpoint describes exactly
    /// the rows read (exclusive boundaries), so a committed pass never claims progress it
    /// did not durably represent.
    static func decodePass(
        databaseURL: URL,
        registeredPath: String,
        baseline: OpenCodeSourceCheckpoint?,
        fingerprint: OpenCodeSourceCheckpoint.Fingerprint,
        rowBudget: Int,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> DecodeResult
    {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, db != nil else {
            let failure = OpenCodeAdapterSourceFailure(db: db, resultCode: openResult)
            if let db { _ = sqlite3_close(db) }
            throw failure
        }
        defer { _ = sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        // Read a short, consistent snapshot; writes commit separately through the store
        // (#4752 point 4).
        try Self.execute(db, "BEGIN")
        defer { try? Self.execute(db, "ROLLBACK") }

        let hasMessage = Self.tableExists(db, "message")
        let hasPart = Self.tableExists(db, "part")
        let hasSession = Self.tableExists(db, "session_message")
        guard hasMessage || hasSession else {
            return DecodeResult(
                checkpoint: OpenCodeSourceCheckpoint.fresh(
                    sourcePath: fingerprint.path,
                    fingerprint: fingerprint),
                complete: true,
                hasPendingContinuation: false,
                wipe: true,
                rawRowsRead: 0,
                usageRows: [],
                aggregates: [],
                globalDeltas: [],
                replacementRowIndices: [],
                deleteRowIndices: [])
        }

        // A source swap beneath the registration invalidates prior windows: fresh wipe
        // (checkpoint provenance keeps a swapped database from inheriting progress).
        var wipe = false
        var checkpoint: OpenCodeSourceCheckpoint
        if let prior = baseline, prior.sourcePath == fingerprint.path {
            checkpoint = prior
        } else {
            wipe = baseline != nil
            checkpoint = OpenCodeSourceCheckpoint.fresh(
                sourcePath: fingerprint.path,
                fingerprint: fingerprint)
        }
        checkpoint.fingerprint = fingerprint

        var budget = max(rowBudget, 1)
        var rawRowsRead = 0
        var usageRows: [CostUsageStoreUsageRow] = []
        var accumulator = AggregateAccumulator()
        var replacements: [Int64] = []
        var deletions: [Int64] = []

        // The durable append boundaries before any pass activity: rowids strictly above
        // these are handled by the append walks, so mutation probes must not double-emit
        // them. Session/news rowswitch.
        let messageBoundaryAtStart = checkpoint.tables.message.high
        let sessionBoundaryAtStart = checkpoint.tables.sessionMessage.high

        // 1. Resume any unfinished oversized message at its exact part position.
        if let pending = checkpoint.pendingPartContinuation, budget > 0 {
            let continuation = try Self.resumeOversizedMessage(
                db,
                continuation: pending,
                budget: &budget,
                registeredPath: registeredPath,
                usageRows: &usageRows,
                accumulator: &accumulator,
                rawRowsRead: &rawRowsRead,
                checkCancellation: checkCancellation)
            checkpoint.pendingPartContinuation = continuation
        } else if checkpoint.pendingPartContinuation == nil {
            // nothing pending
        }

        // 2. Pass body: fresh ingest is newest-first from the top (no upward pass yet —
        //    the upward boundary only ever follows the consumed top row, pinned by the
        //    same SELECT, never a later MAX(rowid)); an existing baseline appends strictly
        //    above its high boundary first.
        if baseline == nil {
            if hasMessage, budget > 0 {
                let result = try Self.walkMessages(
                    db,
                    hasPart: hasPart,
                    upward: false,
                    boundary: Int64.max,
                    budget: budget,
                    registeredPath: registeredPath,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    rawRowsRead: &rawRowsRead,
                    checkCancellation: checkCancellation)
                checkpoint.tables.message.low = result.exhausted ? 0 : result.cursor
                let pinnedTop = result.firstRowid ?? checkpoint.tables.message.high
                checkpoint.tables.message.high = max(checkpoint.tables.message.high, pinnedTop)
                budget = result.remainingBudget
                if result.continuation != nil {
                    checkpoint.pendingPartContinuation = result.continuation
                }
            }
            if hasSession, budget > 0 {
                let result = try Self.walkSessionMessages(
                    db,
                    upward: false,
                    boundary: Int64.max,
                    hasLegacyMessages: hasMessage,
                    hasParts: hasPart,
                    budget: budget,
                    registeredPath: registeredPath,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    rawRowsRead: &rawRowsRead,
                    checkCancellation: checkCancellation)
                checkpoint.tables.sessionMessage.low = result.exhausted ? 0 : result.cursor
                let pinnedTop = result.firstRowid ?? checkpoint.tables.sessionMessage.high
                checkpoint.tables.sessionMessage.high = max(
                    checkpoint.tables.sessionMessage.high, pinnedTop)
                budget = result.remainingBudget
            }
        } else {
            // Appends strictly above the durable high boundary, per table.
            if hasMessage, budget > 0 {
                let result = try Self.walkMessages(
                    db,
                    hasPart: hasPart,
                    upward: true,
                    boundary: checkpoint.tables.message.high,
                    budget: budget,
                    registeredPath: registeredPath,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    rawRowsRead: &rawRowsRead,
                    checkCancellation: checkCancellation)
                checkpoint.tables.message.high = result.cursor
                budget = result.remainingBudget
                if result.continuation != nil {
                    checkpoint.pendingPartContinuation = result.continuation
                }
            }
            if hasSession, budget > 0 {
                let result = try Self.walkSessionMessages(
                    db,
                    upward: true,
                    boundary: checkpoint.tables.sessionMessage.high,
                    hasLegacyMessages: hasMessage,
                    hasParts: hasPart,
                    budget: budget,
                    registeredPath: registeredPath,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    rawRowsRead: &rawRowsRead,
                    checkCancellation: checkCancellation)
                checkpoint.tables.sessionMessage.high = result.cursor
                budget = result.remainingBudget
            }
        }

        // 3. Incomplete fresh ingest continues downward (older rows) below `low` with the
        //    same exclusive boundary — hash-keyed rows keep reevaluation idempotent.
        if hasMessage, budget > 0, checkpoint.tables.message.low > 0 {
            let result = try Self.walkMessages(
                db,
                hasPart: hasPart,
                upward: false,
                boundary: checkpoint.tables.message.low,
                budget: budget,
                registeredPath: registeredPath,
                usageRows: &usageRows,
                accumulator: &accumulator,
                rawRowsRead: &rawRowsRead,
                checkCancellation: checkCancellation)
            checkpoint.tables.message.low = result.exhausted ? 0 : result.cursor
            budget = result.remainingBudget
            if result.continuation != nil {
                checkpoint.pendingPartContinuation = result.continuation
            }
        }
        if hasSession, budget > 0, checkpoint.tables.sessionMessage.low > 0 {
            let result = try Self.walkSessionMessages(
                db,
                upward: false,
                boundary: checkpoint.tables.sessionMessage.low,
                hasLegacyMessages: hasMessage,
                hasParts: hasPart,
                budget: budget,
                registeredPath: registeredPath,
                usageRows: &usageRows,
                accumulator: &accumulator,
                rawRowsRead: &rawRowsRead,
                checkCancellation: checkCancellation)
            checkpoint.tables.sessionMessage.low = result.exhausted ? 0 : result.cursor
            budget = result.remainingBudget
        }

        // 4. Mutation probes (#4752 point 4): upstream UPDATEs rows in place while
        //    streaming. Rows with a newer `time_updated` than the durable watermark are
        //    re-evaluated (their containing message or the session row), replacing the
        //    previously committed contribution at the same identity. Rows above the
        //    current append boundary are skipped — the append pass already covers them.
        //    The watermark advances only to fully processed checkpoint positions.
        if hasMessage, budget > 0 {
            let probe = try Self.probeUpdates(
                db,
                table: "message",
                sinceMs: checkpoint.tables.messageUpdatedMs,
                budget: budget,
                rawRowsRead: &rawRowsRead,
                checkCancellation: checkCancellation)
            budget = probe.remainingBudget
            checkpoint.tables.messageUpdatedMs = probe.exhausted
                ? probe.maxWatermarkedMs
                : max(checkpoint.tables.messageUpdatedMs, probe.maxWatermarkedMs)
            for hit in probe.hits {
                guard hit.rowid <= messageBoundaryAtStart else { continue }
                try Self.reevaluateMessage(
                    db,
                    messageRowid: hit.rowid,
                    messageID: hit.id,
                    hasPart: hasPart,
                    remaining: &budget,
                    registeredPath: registeredPath,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    replacements: &replacements,
                    deletions: &deletions)
            }
        }
        if hasPart, budget > 0 {
            let probe = try Self.probeUpdates(
                db,
                table: "part",
                sinceMs: checkpoint.tables.partUpdatedMs,
                budget: budget,
                rawRowsRead: &rawRowsRead,
                checkCancellation: checkCancellation)
            budget = probe.remainingBudget
            checkpoint.tables.partUpdatedMs = max(checkpoint.tables.partUpdatedMs, probe.maxWatermarkedMs)
            for hit in probe.hits {
                guard hit.rowid <= messageBoundaryAtStart else { continue }
                try Self.reevaluateMessage(
                    db,
                    messageRowid: hit.rowid,
                    messageID: hit.id,
                    hasPart: true,
                    remaining: &budget,
                    registeredPath: registeredPath,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    replacements: &replacements,
                    deletions: &deletions)
            }
        }
        if hasSession, budget > 0 {
            let probe = try Self.probeUpdates(
                db,
                table: "session_message",
                sinceMs: checkpoint.tables.sessionMessageUpdatedMs,
                budget: budget,
                rawRowsRead: &rawRowsRead,
                checkCancellation: checkCancellation)
            budget = probe.remainingBudget
            checkpoint.tables.sessionMessageUpdatedMs = max(
                checkpoint.tables.sessionMessageUpdatedMs, probe.maxWatermarkedMs)
            for hit in probe.hits where hit.rowid <= sessionBoundaryAtStart {
                // Session rows update in place; when a row becomes excluded or invalid
                // the re-evaluation itself deletes its prior contribution.
                try Self.reevaluateSessionRow(
                    db,
                    sessionRowID: hit.rowid,
                    sessionID: hit.id,
                    hasLegacyMessages: hasMessage,
                    hasParts: hasPart,
                    remaining: &budget,
                    registeredPath: registeredPath,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    replacements: &replacements,
                    deletions: &deletions)
            }
        }

        let complete = (!hasMessage || checkpoint.tables.message.low == 0)
            && (!hasSession || checkpoint.tables.sessionMessage.low == 0)
            && checkpoint.pendingPartContinuation == nil
        return DecodeResult(
            checkpoint: checkpoint,
            complete: complete,
            hasPendingContinuation: checkpoint.pendingPartContinuation != nil,
            wipe: wipe,
            rawRowsRead: rawRowsRead,
            usageRows: usageRows,
            aggregates: accumulator.fileAggregates,
            globalDeltas: accumulator.globalDeltas,
            replacementRowIndices: replacements,
            deleteRowIndices: deletions)
    }

    // MARK: - Aggregation

    struct AggregateAccumulator {
        var buckets: [String: CostUsageStoreDayAggregate] = [:]
        var fileAggregates: [CostUsageStoreDayAggregate] {
            self.buckets.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
        }

        /// Append-only semantics: deltas equal exactly this pass's contribution (each raw
        /// row contributes to the store exactly once, guarded by exclusive boundaries).
        var globalDeltas: [CostUsageStoreDayAggregate] {
            self.fileAggregates
        }

        mutating func add(turn: Turn, day: String) {
            let key = day + "␟" + turn.modelID
            var bucket = self.buckets[key] ?? CostUsageStoreDayAggregate.zero(
                day: day, model: turn.modelID)
            let cached = Int64((turn.cacheReadTokens ?? 0) + (turn.cacheCreationTokens ?? 0))
            let input = Int64(turn.inputTokens ?? 0)
            let output = Int64(turn.outputTokens ?? 0)
            bucket.inputTokens += input
            bucket.cachedTokens += cached
            bucket.outputTokens += output
            bucket.reasoningTokens += Int64(turn.reasoningTokens ?? 0)
            bucket.requestCount += 1
            // Authoritative cost surfaces exactly as recorded — including $0 (#4752
            // point 3: presence is the signal, not cost > 0).
            bucket.authoritativeCostNanos += Int64((turn.costUSD * 1e9).rounded())
            bucket.standardInputTokens += input
            bucket.standardCachedTokens += cached
            bucket.standardOutputTokens += output
            // OpenCode has no priority tier; standard channels carry the totals.
            bucket.standardTokens += input + cached + output
            self.buckets[key] = bucket
        }
    }

    // MARK: - Message + part walk

    struct WalkResult {
        var cursor: Int64
        /// The first raw row this SELECT consumed (the top of a DESC walk's range); a
        /// fresh pass pins `high` from it — the same SELECT, never a later MAX(rowid)
        /// (#4744 regression 3).
        var firstRowid: Int64?
        var exhausted: Bool
        var remainingBudget: Int
        var continuation: OpenCodeSourceCheckpoint.PartContinuation?
    }

    /// Walks openai-provider assistant `message` rows across a rowid boundary. Exclusive
    /// boundaries pin against the SELECT itself; exhaustion is a raw-lookahead verdict
    /// (`remaining + 1`). Parts are admitted per message via their `(message_id)` index —
    /// never an all-parts join before admission (#4752 point 5).
    static func walkMessages(
        _ db: OpaquePointer?,
        hasPart: Bool,
        upward: Bool,
        boundary: Int64,
        budget: Int,
        registeredPath: String,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        rawRowsRead: inout Int,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> WalkResult
    {
        guard budget > 0, !upward || boundary < Int64.max else {
            return WalkResult(cursor: boundary, firstRowid: nil,
                              exhausted: upward || boundary <= 0,
                              remainingBudget: budget, continuation: nil)
        }
        var remaining = budget
        let comparison = upward ? ">" : "<"
        let order = upward ? "ASC" : "DESC"
        var stmt: OpaquePointer?
        let sql = """
        SELECT rowid, id, time_created, data
        FROM message
        WHERE rowid \(comparison) \(boundary)
          AND json_valid(data)
          AND json_extract(data, '$.providerID') = 'openai'
          AND json_extract(data, '$.role') = 'assistant'
        ORDER BY rowid \(order)
        LIMIT \(remaining + 1)
        """
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }

        var buffer: [RawMessage] = []
        var exhausted = true
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeAdapterSourceFailure(db: db, resultCode: step)
            }
            if buffer.count == remaining {
                // One raw row beyond budget proves this range is unfinished.
                exhausted = false
                break
            }
            buffer.append(RawMessage(
                rowid: sqlite3_column_int64(stmt, 0),
                id: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                timeCreatedMs: sqlite3_column_int64(stmt, 2),
                data: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""))
            rawRowsRead += 1
        }

        var cursor = boundary
        var continuation: OpenCodeSourceCheckpoint.PartContinuation?
        var processed = 0
        for message in buffer {
            let modelID = Self.messageModelID(message.data)
            let final = hasPart
                ? try Self.evaluateMessage(
                    db,
                    message: message,
                    fromPartRowid: nil,
                    modelID: modelID,
                    remaining: &remaining,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    registeredPath: registeredPath)
                : Self.appendFallbackOnly(
                    message: message,
                    modelID: modelID,
                    usageRows: &usageRows,
                    accumulator: &accumulator,
                    registeredPath: registeredPath)
            processed += 1
            cursor = message.rowid
            if let unfinished = final {
                continuation = unfinished
                exhausted = false
                break
            }
            if remaining <= 0, processed < buffer.count {
                exhausted = false
                break
            }
            try checkCancellation?()
        }
        // Unprocessed buffer messages stay eligible next pass from the last processed row.
        if processed < buffer.count, processed > 0 {
            cursor = buffer[processed - 1].rowid
        } else if processed == 0 {
            cursor = boundary
        }
        return WalkResult(
            cursor: cursor,
            firstRowid: buffer.first?.rowid,
            exhausted: exhausted,
            remainingBudget: max(remaining, 0),
            continuation: continuation)
    }

    /// The no-`part`-table path: a message contributes its own totals, never split.
    private static func appendFallbackOnly(
        message: RawMessage,
        modelID: String,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        registeredPath: String) -> OpenCodeSourceCheckpoint.PartContinuation?
    {
        guard let turn = Self.fallbackTurn(
            id: message.id,
            timeCreatedMs: message.timeCreatedMs,
            data: message.data)
        else { return nil }
        try? Self.append(
            turn: turn,
            usageRows: &usageRows,
            accumulator: &accumulator,
            registeredPath: registeredPath)
        return nil
    }

    /// One raw `message` row as read inside a pass.
    struct RawMessage {
        var rowid: Int64
        var id: String
        var timeCreatedMs: Int64
        var data: String
    }

    /// Resumes an unfinished oversized message at its durable part position — the strict
    /// `(messageRowid, partRowid)` continuation (#4744 regression 2). A message deleted
    /// since clears the continuation without contributing (checkpoint provenance keeps
    /// nothing for rows no longer present).
    static func resumeOversizedMessage(
        _ db: OpaquePointer?,
        continuation: OpenCodeSourceCheckpoint.PartContinuation,
        budget: inout Int,
        registeredPath: String,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        rawRowsRead: inout Int,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> OpenCodeSourceCheckpoint.PartContinuation?
    {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            db,
            "SELECT id, time_created, data FROM message WHERE rowid = \(continuation.messageRowid)",
            -1,
            &stmt,
            nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let message = RawMessage(
            rowid: continuation.messageRowid,
            id: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
            timeCreatedMs: sqlite3_column_int64(stmt, 1),
            data: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "")
        guard Self.isOpenAIAssistant(message.data) else { return nil }
        rawRowsRead += 1
        try checkCancellation?()
        return try Self.evaluateMessage(
            db,
            message: message,
            fromPartRowid: continuation.partRowid,
            modelID: Self.messageModelID(message.data),
            remaining: &budget,
            usageRows: &usageRows,
            accumulator: &accumulator,
            registeredPath: registeredPath)
    }

    /// Evaluates one message's valid `step-finish` parts (one contribution per valid
    /// part) — or its message-level totals via `append` only when no valid part exists and
    /// every part has been seen. Returns a continuation when the pass is out of budget
    /// mid-message.
    private static func evaluateMessage(
        _ db: OpaquePointer?,
        message: RawMessage,
        fromPartRowid: Int64?,
        modelID: String,
        remaining: inout Int,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        registeredPath: String) throws -> OpenCodeSourceCheckpoint.PartContinuation?
    {
        var stmt: OpaquePointer?
        let clause = fromPartRowid.map { " AND rowid > \($0)" } ?? ""
        let sql = """
        SELECT rowid, id, time_created, data
        FROM part
        WHERE message_id = ?\(clause)
        ORDER BY rowid ASC
        """
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, message.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var validParts = 0
        var lastProcessedPartRowid = fromPartRowid ?? 0
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeAdapterSourceFailure(db: db, resultCode: step)
            }
            guard remaining > 0 else {
                return OpenCodeSourceCheckpoint.PartContinuation(
                    messageRowid: message.rowid,
                    partRowid: lastProcessedPartRowid)
            }
            remaining -= 1
            lastProcessedPartRowid = sqlite3_column_int64(stmt, 0)
            let rawData = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            guard let partData = try? JSONDecoder().decode(PartPayload.self, from: Data(rawData.utf8)),
                  partData.type == "step-finish",
                  let cost = partData.cost,
                  cost >= 0, cost.isFinite
            else { continue }
            validParts += 1
            let turn = Turn(
                namespace: Namespace.part.rawValue,
                sourceID: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                createdMs: partData.time?.created ?? sqlite3_column_int64(stmt, 2),
                costUSD: cost,
                modelID: modelID,
                totalTokens: partData.tokens?.computedTotal,
                inputTokens: partData.tokens?.input,
                outputTokens: partData.tokens?.output,
                reasoningTokens: partData.tokens?.reasoning,
                cacheReadTokens: partData.tokens?.cache?.read,
                cacheCreationTokens: partData.tokens?.cache?.write)
            try Self.append(
                turn: turn,
                usageRows: &usageRows,
                accumulator: &accumulator,
                registeredPath: registeredPath)
        }
        if validParts == 0,
           let fallback = Self.fallbackTurn(
               id: message.id,
               timeCreatedMs: message.timeCreatedMs,
               data: message.data)
        {
            try Self.append(
                turn: fallback,
                usageRows: &usageRows,
                accumulator: &accumulator,
                registeredPath: registeredPath)
        }
        return nil
    }

    /// Message-level totals fill in only when no valid part exists (Go-reader
    /// precedence); an unusable message contributes nothing at all.
    private static func fallbackTurn(id: String, timeCreatedMs: Int64, data: String) -> Turn? {
        guard let payload = try? JSONDecoder().decode(MessagePayload.self, from: Data(data.utf8)),
              let cost = payload.cost,
              cost >= 0, cost.isFinite
        else { return nil }
        return Turn(
            namespace: Namespace.message.rawValue,
            sourceID: id,
            createdMs: payload.time?.created ?? timeCreatedMs,
            costUSD: cost,
            modelID: payload.modelID ?? "",
            totalTokens: payload.tokens?.computedTotal,
            inputTokens: payload.tokens?.input,
            outputTokens: payload.tokens?.output,
            reasoningTokens: payload.tokens?.reasoning,
            cacheReadTokens: payload.tokens?.cache?.read,
            cacheCreationTokens: payload.tokens?.cache?.write)
    }

    // MARK: - Session-message walk

    /// Walks v2 `session_message` rows across a rowid boundary. One row per source rowid,
    /// so exclusive boundaries pin cleanly, and the usable-legacy exclusion stays in the
    /// source's SQL (#4587), seeded by index-backed point lookups rather than joins.
    static func walkSessionMessages(
        _ db: OpaquePointer?,
        upward: Bool,
        boundary: Int64,
        hasLegacyMessages: Bool,
        hasParts: Bool,
        budget: Int,
        registeredPath: String,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        rawRowsRead: inout Int,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> WalkResult
    {
        guard budget > 0 else {
            return WalkResult(cursor: boundary, firstRowid: nil, exhausted: false,
                              remainingBudget: 0, continuation: nil)
        }
        var remaining = budget
        let comparison = upward ? ">" : "<"
        let order = upward ? "ASC" : "DESC"
        let usableLegacy = hasParts
            ? """
              AND (
                EXISTS (
                  SELECT 1 FROM part p
                  WHERE p.message_id = m.id AND json_valid(p.data)
                    AND json_extract(p.data, '$.type') = 'step-finish'
                    AND json_type(p.data, '$.cost') IN ('integer', 'real')
                    AND CAST(json_extract(p.data, '$.cost') AS REAL) >= 0)
                OR (json_type(m.data, '$.cost') IN ('integer', 'real')
                    AND CAST(json_extract(m.data, '$.cost') AS REAL) >= 0))
            """
            : """
              AND json_type(m.data, '$.cost') IN ('integer', 'real')
                AND CAST(json_extract(m.data, '$.cost') AS REAL) >= 0
            """
        let legacyExclusion = hasLegacyMessages
            ? """
              AND NOT EXISTS (
                SELECT 1 FROM message m
                WHERE m.id = s.id AND json_valid(m.data)
                  AND json_extract(m.data, '$.providerID') = 'openai'
                  AND json_extract(m.data, '$.role') = 'assistant'
            \(usableLegacy))
            """
            : ""
        var stmt: OpaquePointer?
        let sql = """
        SELECT s.rowid, s.id, s.time_created, s.data
        FROM session_message s
        WHERE s.type = 'assistant' AND json_valid(s.data)
          AND json_extract(s.data, '$.model.providerID') = 'openai'
          AND json_type(s.data, '$.cost') IN ('integer', 'real')
          AND CAST(json_extract(s.data, '$.cost') AS REAL) >= 0
          AND s.rowid \(comparison) \(boundary)\(legacyExclusion)
        ORDER BY s.rowid \(order)
        LIMIT \(remaining + 1)
        """
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }

        var cursor = boundary
        var firstRowid: Int64?
        var exhausted = true
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeAdapterSourceFailure(db: db, resultCode: step)
            }
            guard remaining > 0 else {
                exhausted = false
                break
            }
            remaining -= 1
            rawRowsRead += 1
            let rowid = sqlite3_column_int64(stmt, 0)
            if firstRowid == nil { firstRowid = rowid }
            cursor = rowid
            try checkCancellation?()
            let dataString = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            guard let data = try? JSONDecoder().decode(SessionPayload.self, from: Data(dataString.utf8)),
                  let cost = data.cost, cost >= 0, cost.isFinite
            else { continue }
            let turn = Turn(
                namespace: Namespace.session_message.rawValue,
                sourceID: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                createdMs: data.time?.created ?? sqlite3_column_int64(stmt, 2),
                costUSD: cost,
                modelID: data.model?.id ?? "",
                totalTokens: data.tokens?.computedTotal,
                inputTokens: data.tokens?.input,
                outputTokens: data.tokens?.output,
                reasoningTokens: data.tokens?.reasoning,
                cacheReadTokens: data.tokens?.cache?.read,
                cacheCreationTokens: data.tokens?.cache?.write)
            try Self.append(
                turn: turn,
                usageRows: &usageRows,
                accumulator: &accumulator,
                registeredPath: registeredPath)
        }
        return WalkResult(
            cursor: cursor,
            firstRowid: firstRowid,
            exhausted: exhausted,
            remainingBudget: max(remaining, 0),
            continuation: nil)
    }

    // MARK: - Mutation probe + re-evaluation (#4752 point 4)

    struct UpdateHit {
        var rowid: Int64
        var id: String
    }

    struct UpdateProbe {
        var hits: [UpdateHit]
        var remainingBudget: Int
        var maxWatermarkedMs: Int64
        var exhausted: Bool
    }

    /// Walks rows whose `time_updated` moved since the durable watermark, in a single
    /// read-only source transaction, with the same raw-lookahead budget semantics as the
    /// append walks. For `part`, hits resolve to their parent message (via the parts
    /// message_id index); hits never double-emit rows already covered by the append
    /// walk — the call sites filter by the durable append boundary.
    static func probeUpdates(
        _ db: OpaquePointer?,
        table: String,
        sinceMs: Int64,
        budget: Int,
        rawRowsRead: inout Int,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> UpdateProbe
    {
        var remaining = budget
        var sql: String
        switch table {
        case "message":
            sql = """
            SELECT rowid, id, time_updated
            FROM message
            WHERE time_updated > \(sinceMs)
              AND json_valid(data)
              AND json_extract(data, '$.providerID') = 'openai'
              AND json_extract(data, '$.role') = 'assistant'
            ORDER BY time_updated ASC
            LIMIT \(remaining + 1)
            """
        case "part":
            sql = """
            SELECT m.rowid, m.id, p.time_updated
            FROM part p
            JOIN message m ON m.id = p.message_id
            WHERE p.time_updated > \(sinceMs)
              AND json_valid(m.data)
              AND json_extract(m.data, '$.providerID') = 'openai'
              AND json_extract(m.data, '$.role') = 'assistant'
            ORDER BY p.time_updated ASC
            LIMIT \(remaining + 1)
            """
        case "session_message":
            sql = """
            SELECT s.rowid, s.id, s.time_updated
            FROM session_message s
            WHERE s.time_updated > \(sinceMs)
              AND s.type = 'assistant' AND json_valid(s.data)
              AND json_extract(s.data, '$.model.providerID') = 'openai'
            ORDER BY s.time_updated ASC
            LIMIT \(remaining + 1)
            """
        default:
            return UpdateProbe(hits: [], remainingBudget: remaining, maxWatermarkedMs: sinceMs, exhausted: true)
        }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        var hits: [UpdateHit] = []
        var exhausted = true
        var maxMs = sinceMs
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeAdapterSourceFailure(db: db, resultCode: step)
            }
            guard remaining > 0 else {
                exhausted = false
                break
            }
            remaining -= 1
            rawRowsRead += 1
            let rowid = sqlite3_column_int64(stmt, 0)
            let id = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let updated = max(sqlite3_column_int64(stmt, 2), 0)
            maxMs = max(maxMs, updated)
            hits.append(UpdateHit(rowid: rowid, id: id))
            try checkCancellation?()
        }
        return UpdateProbe(
            hits: hits,
            remainingBudget: max(remaining, 0),
            maxWatermarkedMs: maxMs,
            exhausted: exhausted)
    }

    /// Fully re-evaluates one message at its identity (valid `step-finish` parts now, or
    /// the message-level fallback), and records its re-emitted identity IDs as
    /// replacement swaps plus deletes for contribution footprints that no longer exist.
    /// Old payloads resolve against the store at commit time (#4752 point 4).
    static func reevaluateMessage(
        _ db: OpaquePointer?,
        messageRowid: Int64,
        messageID: String,
        hasPart: Bool,
        remaining: inout Int,
        registeredPath: String,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        replacements: inout [Int64],
        deletions: inout [Int64]) throws
    {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            db,
            "SELECT time_created, data FROM message WHERE rowid = \(messageRowid)",
            -1,
            &stmt,
            nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        let message = RawMessage(
            rowid: messageRowid,
            id: messageID,
            timeCreatedMs: sqlite3_column_int64(stmt, 0),
            data: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "")

        var emitted: [Int64] = []
        if hasPart {
            var emittedParts = 0
            _ = try Self.evaluateMessageInto(
                db,
                message: message,
                fromPartRowid: nil,
                modelID: Self.messageModelID(message.data),
                remaining: &remaining,
                usageRows: &usageRows,
                accumulator: &accumulator,
                registeredPath: registeredPath,
                emittedIdentities: &emitted,
                partsEmitted: &emittedParts)
            if emittedParts > 0 {
                // A message with a valid step-finish cannot keep its old fallback.
                deletions.append(Self.rowIdentity(namespace: .message, sourceID: message.id))
            } else {
                // No valid part now: the fallback rule still applies only when the
                // message itself is usable; otherwise every prior footprint dies.
                let fallbackID = Self.rowIdentity(namespace: .message, sourceID: message.id)
                if !emitted.contains(fallbackID) {
                    deletions.append(fallbackID)
                }
            }
        } else {
            _ = Self.appendFallbackOnly(
                message: message,
                modelID: Self.messageModelID(message.data),
                usageRows: &usageRows,
                accumulator: &accumulator,
                registeredPath: registeredPath)
            emitted.append(Self.rowIdentity(namespace: .message, sourceID: message.id))
        }
        replacements.append(contentsOf: emitted)
    }

    /// Re-evaluates a session row; when it is now excluded by the usable-legacy
    /// projection or invalid, the call reports so — the caller deletes its prior
    /// contribution — otherwise its new emission replaces the old at the same identity.
    static func reevaluateSessionRow(
        _ db: OpaquePointer?,
        sessionRowID: Int64,
        sessionID: String,
        hasLegacyMessages: Bool,
        hasParts: Bool,
        remaining: inout Int,
        registeredPath: String,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        replacements: inout [Int64],
        deletions: inout [Int64]) throws
    {
        let identity = Self.rowIdentity(namespace: .session_message, sourceID: sessionID)
        var stmt: OpaquePointer?
        let usableLegacy = hasParts
            ? """
              EXISTS (
                SELECT 1 FROM part p
                WHERE p.message_id = m.id AND json_valid(p.data)
                  AND json_extract(p.data, '$.type') = 'step-finish'
                  AND json_type(p.data, '$.cost') IN ('integer', 'real')
                  AND CAST(json_extract(p.data, '$.cost') AS REAL) >= 0
              )
              OR (json_type(m.data, '$.cost') IN ('integer', 'real')
                  AND CAST(json_extract(m.data, '$.cost') AS REAL) >= 0)
            """
            : """
              (json_type(m.data, '$.cost') IN ('integer', 'real')
               AND CAST(json_extract(m.data, '$.cost') AS REAL) >= 0)
            """
        let legacyGuard = hasLegacyMessages
            ? """
              AND NOT (
                SELECT COUNT(*) > 0
                FROM message m
                WHERE m.id = s.id AND json_valid(m.data)
                  AND json_extract(m.data, '$.providerID') = 'openai'
                  AND json_extract(m.data, '$.role') = 'assistant'
                  AND \(usableLegacy))
            """
            : ""
        let sql = """
        SELECT s.time_created, s.data
        FROM session_message s
        WHERE s.rowid = \(sessionRowID)
          AND s.type = 'assistant' AND json_valid(s.data)
          AND json_extract(s.data, '$.model.providerID') = 'openai'
          AND json_type(s.data, '$.cost') IN ('integer', 'real')
          AND CAST(json_extract(s.data, '$.cost') AS REAL) >= 0\(legacyGuard)
        """
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        guard remaining > 0 || true else { return }
        let step = sqlite3_step(stmt)
        if step != SQLITE_ROW {
            // Excluded or invalid now: a previous contribution must be removed.
            deletions.append(identity)
            return
        }
        let dataString = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        guard let data = try? JSONDecoder().decode(SessionPayload.self, from: Data(dataString.utf8)),
              let cost = data.cost, cost >= 0, cost.isFinite
        else {
            deletions.append(identity)
            return
        }
        let turn = Turn(
            namespace: Namespace.session_message.rawValue,
            sourceID: sessionID,
            createdMs: data.time?.created ?? sqlite3_column_int64(stmt, 0),
            costUSD: cost,
            modelID: data.model?.id ?? "",
            totalTokens: data.tokens?.computedTotal,
            inputTokens: data.tokens?.input,
            outputTokens: data.tokens?.output,
            reasoningTokens: data.tokens?.reasoning,
            cacheReadTokens: data.tokens?.cache?.read,
            cacheCreationTokens: data.tokens?.cache?.write)
        try Self.append(
            turn: turn,
            usageRows: &usageRows,
            accumulator: &accumulator,
            registeredPath: registeredPath)
        replacements.append(identity)
    }

    /// evaluateMessage variant reporting emitted identity namespaces and the valid-part
    /// count, so re-evaluation swaps can delete the superseded footprints exactly.
    private static func evaluateMessageInto(
        _ db: OpaquePointer?,
        message: RawMessage,
        fromPartRowid: Int64?,
        modelID: String,
        remaining: inout Int,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        registeredPath: String,
        emittedIdentities: inout [Int64],
        partsEmitted: inout Int) throws -> OpenCodeSourceCheckpoint.PartContinuation?
    {
        var stmt: OpaquePointer?
        let clause = fromPartRowid.map { " AND rowid > \($0)" } ?? ""
        let sql = """
        SELECT rowid, id, time_created, data
        FROM part
        WHERE message_id = ?\(clause)
        ORDER BY rowid ASC
        """
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, message.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var validParts = 0
        var lastProcessedPartRowid = fromPartRowid ?? 0
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeAdapterSourceFailure(db: db, resultCode: step)
            }
            guard remaining > 0 else {
                return OpenCodeSourceCheckpoint.PartContinuation(
                    messageRowid: message.rowid,
                    partRowid: lastProcessedPartRowid)
            }
            remaining -= 1
            lastProcessedPartRowid = sqlite3_column_int64(stmt, 0)
            let rawData = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            guard let partData = try? JSONDecoder().decode(PartPayload.self, from: Data(rawData.utf8)),
                  partData.type == "step-finish",
                  let cost = partData.cost,
                  cost >= 0, cost.isFinite
            else { continue }
            validParts += 1
            partsEmitted += 1
            let turn = Turn(
                namespace: Namespace.part.rawValue,
                sourceID: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                createdMs: partData.time?.created ?? sqlite3_column_int64(stmt, 2),
                costUSD: cost,
                modelID: modelID,
                totalTokens: partData.tokens?.computedTotal,
                inputTokens: partData.tokens?.input,
                outputTokens: partData.tokens?.output,
                reasoningTokens: partData.tokens?.reasoning,
                cacheReadTokens: partData.tokens?.cache?.read,
                cacheCreationTokens: partData.tokens?.cache?.write)
            emittedIdentities.append(
                Self.rowIdentity(namespace: .part, sourceID: turn.sourceID))
            try Self.append(
                turn: turn,
                usageRows: &usageRows,
                accumulator: &accumulator,
                registeredPath: registeredPath)
        }
        if validParts == 0,
           let fallback = Self.fallbackTurn(
               id: message.id,
               timeCreatedMs: message.timeCreatedMs,
               data: message.data)
        {
            emittedIdentities.append(
                Self.rowIdentity(namespace: .message, sourceID: fallback.sourceID))
            try Self.append(
                turn: fallback,
                usageRows: &usageRows,
                accumulator: &accumulator,
                registeredPath: registeredPath)
        }
        return nil
    }

    // MARK: - SQL + payload helpers

    static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeAdapterSourceFailure(db: db, resultCode: sqlite3_errcode(db))
        }
    }

    static func tableExists(_ db: OpaquePointer?, _ table: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(table)'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { _ = sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    static func isOpenAIAssistant(_ json: String) -> Bool {
        (try? JSONDecoder().decode(MessageEnvelope.self, from: Data(json.utf8)))
            .map { $0.providerID == "openai" && $0.role == "assistant" } ?? false
    }

    static func messageModelID(_ json: String) -> String {
        (try? JSONDecoder().decode(MessagePayload.self, from: Data(json.utf8)))?.modelID ?? ""
    }

    private static func append(
        turn: Turn,
        usageRows: inout [CostUsageStoreUsageRow],
        accumulator: inout AggregateAccumulator,
        registeredPath: String) throws
    {
        guard turn.createdMs > 0 else { return }
        let day = Self.dayKey(fromUnixMs: turn.createdMs)
        accumulator.add(turn: turn, day: day)
        usageRows.append(CostUsageStoreUsageRow(
            path: registeredPath,
            rowIndex: Int(self.rowIdentity(
                namespace: Namespace(rawValue: turn.namespace) ?? .part,
                sourceID: turn.sourceID)),
            payload: try JSONEncoder().encode(turn)))
    }

    /// The store pins the reporting calendar at publication; the adapter buckets turns by
    /// UTC day here so identical ms map to one day key regardless of the read-side
    /// calendar choice (the read view re-buckets natively).
    static func dayKey(fromUnixMs ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private struct MessageEnvelope: Decodable {
        var providerID: String?
        var role: String?
    }

    private struct MessagePayload: Decodable {
        struct Time: Decodable { var created: Int64? }
        var providerID: String?
        var role: String?
        var modelID: String?
        var cost: Double?
        var time: Time?
        var tokens: TokenCounts?
    }

    private struct PartPayload: Decodable {
        struct Time: Decodable { var created: Int64? }
        var type: String?
        var cost: Double?
        var time: Time?
        var tokens: TokenCounts?
    }

    private struct SessionPayload: Decodable {
        struct Time: Decodable { var created: Int64? }
        struct Model: Decodable { var id: String? }
        var model: Model?
        var cost: Double?
        var time: Time?
        var tokens: TokenCounts?
    }

    struct TokenCounts: Decodable {
        struct Cache: Decodable { var read: Int?; var write: Int? }
        var total: Int?
        var input: Int?
        var output: Int?
        var reasoning: Int?
        var cache: Cache?

        var computedTotal: Int? {
            if let total { return total }
            let parts = [self.input, self.output, self.reasoning, self.cache?.read, self.cache?.write]
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            return (self.input ?? 0) + (self.output ?? 0) + (self.reasoning ?? 0)
                + (self.cache?.read ?? 0) + (self.cache?.write ?? 0)
        }
    }
}
#endif

struct OpenCodeAdapterSourceFailure: Error {
    let code: Int32

    init(db: OpaquePointer?, resultCode: Int32) {
        self.code = resultCode
        _ = db
    }
}
