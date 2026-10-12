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
        /// An explicit custom rate for the priced model also wins: overlays keep precedence over dated pricing
        /// changes, and the waiver is one. The request is then priced like any other custom-priced request.
        static func isIncluded(
            _ row: CodexUsageRow,
            hasCreatorAccount: Bool?,
            customPricing: CostUsageCustomPricing,
            priorityTurns: [String: CodexPriorityTurnMetadata]) -> Bool
        {
            guard hasCreatorAccount == true,
                  row.knownCostNanos == nil,
                  let timestamp = row.timestampUnixMs,
                  timestamp >= self.autoReviewIncludedSinceUnixMs,
                  CostUsagePricing.normalizeCodexModel(row.model) == self.autoReviewModel
            else { return false }
            let pricedModel = CostUsageScanner.codexPricedModel(for: row, priorityTurns: priorityTurns)
            return customPricing.rates(providerID: CostUsagePricing.codexModelsDevProviderID, model: pricedModel) == nil
        }
    }

    /// Report-time classification: the file's session metadata decides, so the persisted rows stay unchanged.
    static func codexFileUsageMarkingIncludedRows(
        _ usage: CostUsageFileUsage,
        customPricing: CostUsageCustomPricing,
        priorityTurns: [String: CodexPriorityTurnMetadata]) -> CostUsageFileUsage
    {
        let hasCreatorAccount = usage.codexSession?.hasCreatorAccount
        let isIncluded = { (row: CodexUsageRow) in
            CodexIncludedUsage.isIncluded(
                row,
                hasCreatorAccount: hasCreatorAccount,
                customPricing: customPricing,
                priorityTurns: priorityTurns)
        }
        guard hasCreatorAccount == true,
              let rows = usage.codexRows,
              rows.contains(where: isIncluded)
        else { return usage }
        var updated = usage
        updated.codexRows = rows.map { row in
            guard isIncluded(row) else { return row }
            var row = row
            row.isIncludedInPlan = true
            return row
        }
        return updated
    }
}
