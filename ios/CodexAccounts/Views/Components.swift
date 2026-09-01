import SwiftUI

struct DevicePicker: View {
    @Environment(AppStore.self) private var store
    @State private var showingDevices = false

    var body: some View {
        Button { showingDevices = true } label: {
            HStack(spacing: 10) {
                Image(systemName: store.selectedDevice?.platform == .windows ? "desktopcomputer" : "laptopcomputer")
                    .foregroundStyle(Theme.cobalt).frame(width: 30)
                Text(store.selectedDevice?.name ?? "Select device").font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Circle().fill(store.selectedDevice?.onlineState == .online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(store.selectedDevice?.onlineState == .online ? "Online" : "Offline").font(.footnote).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 48).padding(.horizontal, 14)
            .background(Theme.surface, in: .rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityHint("Switch device")
        .sheet(isPresented: $showingDevices) { DeviceSelectorView() }
    }
}

struct SyncMeta: View {
    @Environment(AppStore.self) private var store
    var scopedDescription: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if store.isSyncing { ProgressView().controlSize(.mini) }
            Text(scopedDescription ?? syncText).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button { Task { await store.sync() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(Theme.cobalt).frame(minWidth: 44, minHeight: 28)
        }
    }
    private var syncText: String {
        guard let snapshot = store.selectedSnapshot else { return "Not synced yet" }
        return "Synced \(snapshot.observedAt.formatted(.relative(presentation: .named))), \(snapshot.accounts.count) accounts"
    }
}

struct PlanChip: View {
    let plan: String
    var body: some View {
        Text(plan.uppercased()).font(.caption2.weight(.bold))
            .foregroundStyle(plan.lowercased() == "free" ? .secondary : Theme.cobalt)
            .padding(.horizontal, 12).frame(minHeight: 26)
            .background(plan.lowercased() == "free" ? Theme.surface2 : Theme.accentSoft, in: .capsule)
    }
}

struct QuotaRow: View {
    let quota: RateLimitWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(quota.displayName).font(.subheadline.weight(.medium))
                Spacer()
                Text(QuotaFormatter.percent(quota.remainingPercent)).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(Theme.cobalt)
            }
            ProgressView(value: quota.remainingPercent, total: 100).tint(Theme.cobalt).accessibilityLabel(quota.displayName)
            Text(QuotaFormatter.resetDescription(quota.resetsAt)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

struct AccountCard: View {
    let row: AccountRowModel
    var body: some View {
        NavigationLink(value: row.account) {
            if row.isCurrent { currentContent } else { compactContent }
        }
        .buttonStyle(.plain)
    }

    private var currentContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(Theme.cobalt).frame(width: 9, height: 9)
                Text(row.account.displayName).font(.title3.weight(.bold)).lineLimit(1)
                Spacer(); PlanChip(plan: row.account.planType)
            }
            Text(row.account.email).font(.caption).foregroundStyle(.secondary)
            ForEach(row.quotas.sorted { $0.durationMins < $1.durationMins }) { QuotaRow(quota: $0) }
            if row.quotas.isEmpty { Text("No quota").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8) }
        }
        .padding(16).card(emphasized: true)
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.account.displayName).font(.headline).lineLimit(1)
                Text(row.account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                PlanChip(plan: row.account.planType)
                Text(trailingQuota)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(row.longestQuota == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.cobalt))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).frame(minHeight: 72).card()
    }
    private var trailingQuota: String {
        guard let quota = row.longestQuota else { return "No quota data" }
        return "\(quota.displayName.replacingOccurrences(of: " quota", with: "")) \(QuotaFormatter.percent(quota.remainingPercent))"
    }
}

struct EmptyState: View {
    let title: String; let message: String; var systemImage = "tray"
    var body: some View { ContentUnavailableView(title, systemImage: systemImage, description: Text(message)) }
}
