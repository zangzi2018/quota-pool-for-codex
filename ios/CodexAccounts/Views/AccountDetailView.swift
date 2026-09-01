import SwiftUI

struct AccountDetailView: View {
    @Environment(AppStore.self) private var store
    let account: Account
    private var row: AccountRowModel? { store.rows.first { $0.account.id == account.id } }
    private var summary: ResetCreditSummary? { store.resetSummaries.first { $0.accountId == account.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(account.displayName).font(.title3.weight(.bold)); Spacer(); PlanChip(plan: account.planType) }
                    Text(account.email).font(.subheadline).foregroundStyle(.secondary)
                    if row?.isCurrent == true { Text("Current device: \(store.selectedDevice?.name ?? "")").font(.footnote.weight(.medium)).foregroundStyle(Theme.cobalt) }
                }.padding(16).card(emphasized: row?.isCurrent == true)
                sectionTitle("Plan")
                NavigationLink { RenewalEditorView(account: account) } label: { detailRow("ChatGPT \(account.planType.capitalized)", subtitle: "Renewal dates are set manually", trailing: account.renewalAt?.formatted(.dateTime.month().day()) ?? "Not set") }.buttonStyle(.plain)
                if let quotas = row?.quotas, !quotas.isEmpty {
                    sectionTitle("Quota")
                    VStack(spacing: 14) { ForEach(quotas.sorted { $0.durationMins < $1.durationMins }) { QuotaRow(quota: $0) } }.padding(16).card()
                }
                sectionTitle("More info")
                detailRow("Saved rate-limit resets", subtitle: summary.map { "\($0.availableCount) available resets" } ?? "No data", trailing: summary?.credits?.compactMap(\.expiresAt).min()?.formatted(.dateTime.month().day()) ?? "View")
                detailRow("Seen on", subtitle: "Devices for this account", trailing: "View")
            }.padding()
        }.background(Theme.canvas).navigationTitle("Account details").navigationBarTitleDisplayMode(.inline)
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.title3.weight(.bold)) }
    private func detailRow(_ title: String, subtitle: String, trailing: String) -> some View {
        HStack { VStack(alignment: .leading, spacing: 2) { Text(title).font(.body); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(trailing).font(.footnote).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }.padding(16).frame(minHeight: 64).card()
    }
}

struct RenewalEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @State private var enabled: Bool
    @State private var date: Date
    init(account: Account) { self.account = account; _enabled = State(initialValue: account.renewalAt != nil); _date = State(initialValue: account.renewalAt ?? .now) }
    var body: some View {
        Form { Toggle("Renewal dates are set manually", isOn: $enabled); if enabled { DatePicker("Renewal", selection: $date, displayedComponents: .date) } }
            .navigationTitle("Renewal date").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { store.updateRenewal(accountID: account.id, date: enabled ? date : nil); dismiss() } label: { Image(systemName: "checkmark") }.buttonStyle(.borderedProminent) } }
    }
}
