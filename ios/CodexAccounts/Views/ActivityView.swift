import SwiftUI

private enum ActivityFilter: String, CaseIterable, Identifiable { case all = "All"; case quota = "Quota"; case resets = "Resets"; var id: Self { self } }

struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = ActivityFilter.all
    private var events: [ActivityEvent] {
        (store.selectedSnapshot?.activity ?? []).filter {
            switch filter { case .all: true; case .quota: [.quotaChanged, .quotaRefreshed, .quotaReset].contains($0.type); case .resets: [.resetAdded, .resetExpired].contains($0.type) }
        }.sorted { $0.occurredAt > $1.occurredAt }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                DevicePicker(); SyncMeta(scopedDescription: "Show events for the selected device only")
                Picker("Event type", selection: $filter) { ForEach(ActivityFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if events.isEmpty { EmptyState(title: "No activity", message: "No events for this filter", systemImage: "clock") }
                ForEach(events) { event in ActivityRow(event: event) }
            }.padding(.horizontal).padding(.bottom)
        }.background(Theme.canvas).navigationTitle("Activity")
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    private var color: Color {
        switch event.type { case .quotaRefreshed, .quotaReset: .green; case .resetAdded, .resetExpired: .orange; case .deviceOffline: .gray; default: Theme.cobalt }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 10, height: 10)
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 2).frame(minHeight: 52)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text(event.payload["title"] ?? event.type.rawValue).font(.headline); Text(event.payload["detail"] ?? "").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Text(event.occurredAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }.padding(14).frame(minHeight: 64).card()
        }
    }
}
