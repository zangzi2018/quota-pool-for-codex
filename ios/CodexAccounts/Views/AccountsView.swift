import SwiftUI

struct AccountsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                DevicePicker()
                HStack {
                    SyncMeta()
                    NavigationLink { DeviceUsageView() } label: { Text("Activity").font(.caption.weight(.semibold)); Image(systemName: "chevron.right").font(.caption2.weight(.bold)) }
                        .foregroundStyle(Theme.cobalt).accessibilityHint("View device token activity")
                }
                if store.rows.isEmpty { EmptyState(title: "No accounts", message: "Device is present, but no accounts have been read", systemImage: "person.crop.circle.badge.questionmark") }
                ForEach(store.rows) { AccountCard(row: $0) }
                if !upcoming.isEmpty {
                    Text("Up next").font(.title3.weight(.bold)).padding(.top, 4)
                    ForEach(upcoming.prefix(3)) { event in UpcomingCard(event: event) }
                }
            }.padding(.horizontal).padding(.bottom)
        }
        .background(Theme.canvas)
        .navigationTitle("Hub")
        .navigationDestination(for: Account.self) { AccountDetailView(account: $0) }
        .alert("Sync notes", isPresented: .init(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") {} } message: { Text(store.errorMessage ?? "") }
    }

    private var upcoming: [UpcomingEvent] {
        guard let snapshot = store.selectedSnapshot else { return [] }
        var result = snapshot.rateLimitWindows.map { quota in
            UpcomingEvent(id: "quota-\(quota.id)", title: "\(quota.displayName) reset", detail: snapshot.accounts.first(where: { $0.id == quota.accountId })?.displayName ?? "Accounts", date: quota.resetsAt, kind: .quota)
        }
        for summary in store.resetSummaries {
            guard let first = summary.credits?.compactMap(\.expiresAt).min(), let account = snapshot.accounts.first(where: { $0.id == summary.accountId }) else { continue }
            result.append(UpcomingEvent(id: "credit-\(summary.accountId)", title: "Saved rate-limit reset expiry", detail: account.displayName, date: first, kind: .credit))
        }
        for account in snapshot.accounts { if let date = account.renewalAt { result.append(UpcomingEvent(id: "renew-\(account.id)", title: "Subscription renewal", detail: account.displayName, date: date, kind: .renewal)) } }
        return result.sorted { $0.date < $1.date }
    }
}

private enum UpcomingKind { case quota, credit, renewal }
private struct UpcomingEvent: Identifiable { let id, title, detail: String; let date: Date; let kind: UpcomingKind }
private struct UpcomingCard: View {
    let event: UpcomingEvent
    @State private var isExpanded = false
    var body: some View {
        Button { withAnimation(.snappy) { isExpanded.toggle() } } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) { Text(event.title).font(.headline); Text(event.detail).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(event.date, format: .dateTime.month().day()).font(.footnote.weight(.medium)).foregroundStyle(event.kind == .quota ? Theme.cobalt : .secondary).monospacedDigit()
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                if isExpanded {
                    Divider()
                    HStack {
                        Label("Exact time", systemImage: "calendar.badge.clock").foregroundStyle(.secondary)
                        Spacer()
                        Text(event.date, format: .dateTime.year().month().day().hour().minute()).monospacedDigit()
                    }.font(.footnote)
                    Text(event.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 60).card()
        }.buttonStyle(.plain).accessibilityHint(isExpanded ? "Hide details" : "Show details")
    }
}
