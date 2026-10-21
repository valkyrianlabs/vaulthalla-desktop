import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Every reservation and charge the budgets recorded, newest first (`pricing.budget.ledger.list`).
struct CostLedgerView: View {
    var queries: NodeQueries
    var lookup: VaultLookup

    var body: some View {
        let ledger = queries.query(Ws.Pricing.Budget.Ledger.List.self, .init(limit: 200))
        VStack(alignment: .leading, spacing: 0) {
            switch ledger.state {
            case .idle, .loading:
                LoadingPanel(subject: "the ledger")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                Panel { InlineProblem(error: error, subject: "the budget ledger") }
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, _):
                if value.ledger.isEmpty {
                    Panel {
                        EmptyState("Nothing recorded yet", systemImage: "list.bullet.rectangle",
                                   message: "Budgets in report, warn or enforce mode record each sync's estimated cost here.")
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    table(value.ledger)
                }
            }
        }
        .observing(ledger, polling: .seconds(60))
    }

    private func table(_ entries: [WsModel.PriceBudgetLedgerEntry]) -> some View {
        Table(entries.map(LedgerRow.init)) {
            TableColumn("When") { entry in
                Text(CostFormat.relative(entry.createdAt) ?? entry.createdAt)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
                    .help(CostFormat.moment(entry.createdAt) ?? entry.createdAt)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Vault") { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(lookup.name(entry.vaultID) ?? "—").foregroundStyle(.fg)
                    Text(CostFormat.provider(entry.providerKey) ?? "—")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
                .padding(.vertical, 2)
            }
            .width(min: 140, ideal: 200)

            TableColumn("Window") { entry in
                Text(CostFormat.window(entry.window)).foregroundStyle(.fgMuted)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Cost") { entry in
                HStack(spacing: 6) {
                    MoneyText(amount: entry.committedCost ?? entry.reservedCost, currency: entry.currency)
                        .foregroundStyle(.fg)
                    Text(entry.committedCost != nil ? "committed" : "reserved")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
            }
            .width(min: 120, ideal: 160)

            TableColumn("Status") { entry in
                Text(Format.words(entry.status)).foregroundStyle(.fgMuted)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Source") { entry in
                Text([entry.usageSource.map(Format.words), entry.synthetic ? "synthetic" : nil]
                    .compactMap(\.self).joined(separator: " · ").nonEmpty ?? "—")
                    .foregroundStyle(.fgSubtle)
            }
            .width(min: 80, ideal: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
    }
}

/// A table row: the ledger entry, identified by its id.
@dynamicMemberLookup
private struct LedgerRow: Identifiable {
    var entry: WsModel.PriceBudgetLedgerEntry
    var id: Int64 { entry.id }

    subscript<T>(dynamicMember path: KeyPath<WsModel.PriceBudgetLedgerEntry, T>) -> T { entry[keyPath: path] }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
