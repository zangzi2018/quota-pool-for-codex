import SwiftUI

private enum ResetMode: String, CaseIterable, Identifiable { case global = "Rate-limit reset"; case banked = "Saved rate-limit resets"; var id: Self { self } }
private enum CreditFilter: String, CaseIterable, Identifiable { case all = "All"; case expiring = "Expiring soon"; case history = "History"; var id: Self { self } }

struct ResetsView: View {
    @Environment(AppStore.self) private var store
    @State private var mode = ResetMode.global
    @State private var filter = CreditFilter.all

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                DevicePicker()
                SyncMeta(scopedDescription: "Show accounts on the selected device only")
                TiboWatchCard()
                Picker("Reset type", selection: $mode) { ForEach(ResetMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if mode == .global { globalContent } else { bankedContent }
            }.padding(.horizontal).padding(.bottom)
        }.background(Theme.canvas).navigationTitle("Resets")
    }

    @ViewBuilder private var globalContent: some View {
        if let last = store.selectedSnapshot?.globalRateLimitResets.sorted(by: { $0.occurredAt > $1.occurredAt }).first {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latest rate-limit reset").font(.footnote).foregroundStyle(.secondary)
                HStack { Text(last.occurredAt, format: .dateTime.month().day().hour().minute()).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(Theme.cobalt); Spacer(); Text("All accounts").font(.footnote.weight(.semibold)).foregroundStyle(Theme.cobalt) }
                Text(last.note ?? "Applied to all users at the same time").font(.footnote).foregroundStyle(.secondary)
            }.padding(16).background(Theme.accentSoft, in: .rect(cornerRadius: Theme.compactRadius, style: .continuous))
        } else { EmptyState(title: "No rate-limit resets", message: "No verified global reset records", systemImage: "arrow.counterclockwise") }
        Text("Accounts on the selected device").font(.title3.weight(.bold)).padding(.top, 4)
        ForEach(store.rows) { row in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.account.displayName + (row.isCurrent ? " (current)" : "")).font(.headline)
                    Text("\(row.account.planType.capitalized) · \(row.account.email)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) { Text("Reset").font(.footnote.weight(.semibold)).foregroundStyle(.green); Text("\(store.selectedSnapshot?.globalRateLimitResets.count ?? 0) total").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }.padding(16).frame(minHeight: 66).card(emphasized: row.isCurrent)
        }
        Text("5-hour and weekly quotas are account usage windows and are not counted as rate-limit resets.")
            .font(.caption).foregroundStyle(.secondary).padding(16).background(Theme.surface2, in: .rect(cornerRadius: Theme.compactRadius, style: .continuous))
    }

    @ViewBuilder private var bankedContent: some View {
        Picker("Filter", selection: $filter) { ForEach(CreditFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
        let summaries = store.resetSummaries
        if summaries.isEmpty { EmptyState(title: "No saved rate-limit resets", message: "No account data for the selected device yet", systemImage: "archivebox") }
        ForEach(summaries, id: \.accountId) { summary in
            if let account = store.selectedSnapshot?.accounts.first(where: { $0.id == summary.accountId }) {
                CreditCard(account: account, summary: summary, filter: filter)
            }
        }
        Text("iPhone can view saved rate-limit resets but cannot redeem them.")
            .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 2)
    }
}

private struct TiboWatchCard: View {
    @Environment(AppStore.self) private var store
    private var announcement: TiboAnnouncement? { store.snapshots.compactMap(\.tiboAnnouncement).max { $0.observedAt < $1.observedAt } }
    private var evidence: GlobalResetDetector.Result { store.resetEvidence }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TIBO WATCH").font(.caption.weight(.bold)).foregroundStyle(Theme.cobalt)
                Spacer(); Text(stateTitle).font(.caption.weight(.bold)).foregroundStyle(Theme.cobalt).padding(.horizontal, 12).padding(.vertical, 6).background(Theme.accentSoft, in: .capsule)
            }
            Text(headline).font(.title3.weight(.bold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if !evidence.environments.isEmpty {
                Divider()
                ForEach(evidence.environments) { environment in
                    HStack(spacing: 8) {
                        Circle().fill(environment.onlineState == .online ? .green : .secondary).frame(width: 6, height: 6)
                        Text(environment.deviceName).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(changeText(environment)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(environment.resetObserved ? "Confirmed" : environment.onlineState == .online ? "Waiting for a change" : "Offline")
                            .font(.caption2.weight(.bold)).foregroundStyle(environment.resetObserved ? .green : .secondary)
                    }
                }
            }
        }.padding(16).card()
    }
    private var stateTitle: String { switch evidence.state { case .none: "No signal"; case .announcementObserved: "Observed"; case .resetExpected: "Expected reset"; case .waitingConfirmation: "Waiting for confirmation"; case .possibleGlobalReset: "Possible reset"; case .confirmed: "Confirmed" } }
    private var headline: String { evidence.state == .confirmed ? "Observed a global reset" : announcement == nil ? "Waiting for a reliable announcement or device evidence" : "A reset may be coming" }
    private var detail: String {
        if let announcement { return "\(announcement.sourceName) · \(announcement.summary). Confirm with quota changes observed by Quota Pool." }
        return "No live Tibo/X provider is connected. The global reset detector still compares quota changes across devices."
    }
    private func changeText(_ environment: GlobalResetDetector.EnvironmentEvidence) -> String {
        guard environment.onlineState != .offline else { return "—" }
        let current = environment.currentRemaining.map { "\(Int($0.rounded()))%" } ?? "—"
        guard let previous = environment.previousRemaining else { return current }
        return "\(Int(previous.rounded()))% → \(current)"
    }
}

private struct CreditCard: View {
    let account: Account; let summary: ResetCreditSummary; let filter: CreditFilter
    private var credits: [ResetCredit] {
        let now = Date.now
        return (summary.credits ?? []).filter { credit in
            switch filter {
            case .all: true
            case .expiring: credit.status == "available" && credit.expiresAt.map { $0.timeIntervalSince(now) < 3 * 86400 } == true
            case .history: credit.status != "available"
            }
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { VStack(alignment: .leading, spacing: 2) { Text(account.displayName).font(.headline); Text("\(account.planType.capitalized) · \(account.email)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Text("\(summary.availableCount) available").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.cobalt).padding(.horizontal, 14).frame(minHeight: 34).background(Theme.accentSoft, in: .capsule) }
            ForEach(credits) { credit in
                HStack { VStack(alignment: .leading, spacing: 1) { Text(credit.title ?? "Rate-limit reset").font(.subheadline.weight(.semibold)); Text(credit.status == "available" ? "Available" : "Expired").font(.caption2).foregroundStyle(credit.status == "available" ? .green : .secondary) }; Spacer(); if let date = credit.expiresAt { Text(date, format: .dateTime.month().day().hour().minute()).font(.footnote).foregroundStyle(.secondary).monospacedDigit() } }
            }
            if summary.hasPartialDetails { Text("\(summary.availableCount) available, \(summary.credits?.count ?? 0) details returned").font(.caption).foregroundStyle(.orange) }
            if credits.isEmpty { Text(filter == .history ? "No history" : "No details for this filter").font(.footnote).foregroundStyle(.secondary) }
        }.padding(16).card()
    }
}
