import Foundation

extension CostUsageScanner {
    /// Requests that OpenAI excludes from plan usage. They keep their tokens and are priced at an exact $0
    /// instead of being reported as unpriced.
    enum CodexIncludedUsage {
        static let autoReviewModel = "codex-auto-review"
        /// OpenAI made Auto-review checks free for ChatGPT sign-in on 2026-10-06; midnight US Pacific (PDT).
        static let autoReviewIncludedSinceUnixMs: Int64 = 1_791_270_000_000

        /// Missing evidence (no request instant, no creator account, or an unparsed flag) keeps the request
        /// unpriced, so a gap over-reports cost rather than hiding it. A retained authoritative amount wins.
        static func isIncluded(_ row: CodexUsageRow, hasCreatorAccount: Bool?) -> Bool {
            guard hasCreatorAccount == true,
                  row.knownCostNanos == nil,
                  let timestamp = row.timestampUnixMs,
                  timestamp >= self.autoReviewIncludedSinceUnixMs
            else { return false }
            return CostUsagePricing.normalizeCodexModel(row.model) == self.autoReviewModel
        }
    }

    /// Report-time classification: the file's session metadata decides, so the persisted rows stay unchanged.
    static func codexFileUsageMarkingIncludedRows(_ usage: CostUsageFileUsage) -> CostUsageFileUsage {
        let hasCreatorAccount = usage.codexSession?.hasCreatorAccount
        guard hasCreatorAccount == true,
              let rows = usage.codexRows,
              rows.contains(where: { CodexIncludedUsage.isIncluded($0, hasCreatorAccount: hasCreatorAccount) })
        else { return usage }
        var updated = usage
        updated.codexRows = rows.map { row in
            guard CodexIncludedUsage.isIncluded(row, hasCreatorAccount: hasCreatorAccount) else { return row }
            var row = row
            row.isIncludedInPlan = true
            return row
        }
        return updated
    }
}
