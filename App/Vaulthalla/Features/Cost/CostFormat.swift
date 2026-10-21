import Foundation
import VHContract

/// How the pricing commands' values read. Money arrives as decimal strings with catalog precision; a missing amount
/// stays missing ("not estimated"), never $0.00. Timestamps are PostgreSQL text ("2026-10-20 12:00:00.5+00").
nonisolated enum CostFormat {
    static let notEstimated = "not estimated"

    /// `amount` in `currency`, or nil when there is no amount to show. Cents, unless the amount is smaller than a
    /// cent: then enough digits to be honest about it (the web's `formatMoney`).
    static func money(_ amount: String?, _ currency: String?) -> String? {
        guard let text = amount?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        let code = currency.flatMap { $0.isEmpty ? nil : $0.uppercased() } ?? "USD"
        let magnitude = abs(NSDecimalNumber(decimal: value).doubleValue)
        let digits = magnitude == 0 || magnitude >= 0.01 ? 2 : min(8, max(2, Int(-floor(log10(magnitude))) + 2))
        return value.formatted(.currency(code: code).precision(.fractionLength(digits)))
    }

    static func money(_ money: WsModel.RecoveryMoney?) -> String? {
        money.flatMap { self.money($0.amount, $0.currency) }
    }

    /// Whether a decimal string is a positive amount.
    static func isPositive(_ amount: String?) -> Bool {
        guard let amount, let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else {
            return false
        }
        return value > 0
    }

    /// A plain amount a person typed: digits with up to 8 fractional digits ("25", "12.50").
    static func isDecimal(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\d{1,12}(\.\d{1,8})?/) != nil
    }

    // MARK: Time

    /// ISO-8601 or PostgreSQL timestamp text; nil when unreadable.
    static func date(_ text: String?) -> Date? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        text = text.replacingOccurrences(of: " ", with: "T")
        if text.contains(/[+-]\d{2}$/) { text += ":00" } else if !text.contains(/(Z|[+-]\d{2}:?\d{2})$/) { text += "Z" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// "3 min ago", or nil when unreadable.
    static func relative(_ text: String?) -> String? {
        date(text).map { Format.relative($0) }
    }

    static func moment(_ text: String?) -> String? {
        date(text)?.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Words

    static func scope(_ scope: String?) -> String {
        switch scope {
        case WsModel.PriceBudgetPolicy.Scope.global: "All S3 storage"
        case WsModel.PriceBudgetPolicy.Scope.provider: "Provider"
        case WsModel.PriceBudgetPolicy.Scope.vault: "Vault"
        case WsModel.PriceBudgetPolicy.Scope.gatewayCredential: "Gateway key"
        case WsModel.PriceBudgetPolicy.Scope.gatewayCredentialVault: "Gateway key on vault"
        case let other?: Format.words(other)
        case nil: "Unknown"
        }
    }

    static func window(_ window: String?) -> String {
        switch window {
        case WsModel.PriceBudgetTrendStats.WindowType.monthly, "month": "Monthly"
        case WsModel.PriceBudgetTrendStats.WindowType.daily, "day": "Daily"
        case WsModel.PriceBudgetTrendStats.WindowType.perRun, "run": "Per run"
        case let other?: Format.words(other)
        case nil: "—"
        }
    }

    /// Provider keys the daemon accepts for provider budgets (ops::pricing).
    static let providers: [(key: String, label: String)] = [("aws-s3", "AWS S3"), ("cloudflare-r2", "Cloudflare R2")]

    static func provider(_ key: String?) -> String? {
        guard let key else { return nil }
        return providers.first { $0.key == key }?.label ?? key
    }

    static func mode(_ mode: String) -> String {
        switch mode {
        case WsModel.PriceBudgetPolicy.Mode.off: "Off"
        case WsModel.PriceBudgetPolicy.Mode.report: "Report"
        case WsModel.PriceBudgetPolicy.Mode.warn: "Warn"
        case WsModel.PriceBudgetPolicy.Mode.enforce: "Enforce"
        default: Format.words(mode)
        }
    }

    static func modeHint(_ mode: String) -> String {
        switch mode {
        case WsModel.PriceBudgetPolicy.Mode.off: "No checks."
        case WsModel.PriceBudgetPolicy.Mode.report: "Record estimated spend; never warn or block."
        case WsModel.PriceBudgetPolicy.Mode.warn: "Notify when a limit would be exceeded, but let syncs run."
        case WsModel.PriceBudgetPolicy.Mode.enforce: "Stall syncs that would exceed a limit until an override is approved."
        default: ""
        }
    }

    /// A policy's limits in one line: "$25.00 / month · $5.00 / day", or what having none means.
    static func limits(_ policy: WsModel.PriceBudgetPolicy?) -> String {
        guard let policy, policy.isActive else { return "—" }
        let parts = [
            money(policy.maxMonthlyCost, policy.currency).map { "\($0) / month" },
            money(policy.maxDailyCost, policy.currency).map { "\($0) / day" },
            money(policy.maxRunCost, policy.currency).map { "\($0) / run" },
        ].compactMap(\.self)
        return parts.isEmpty ? "No limits (records only)" : parts.joined(separator: " · ")
    }
}
