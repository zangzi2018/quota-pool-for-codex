import SwiftUI

struct SessionsView: View {
    @Environment(AppStore.self) private var store

    private var running: [SessionSummary] { store.sessionSummaries.filter { $0.runtimeState == .active } }
    private var recent: [SessionSummary] { store.sessionSummaries.filter { $0.runtimeState != .active } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                summaryCard
                    .accessibilityIdentifier("sessions-summary")
                if !running.isEmpty {
                    sectionTitle("Running")
                    ForEach(running) { SessionRow(session: $0) }
                }
                if !recent.isEmpty {
                    sectionTitle("Recent")
                    ForEach(recent) { SessionRow(session: $0) }
                }
                if store.sessionSummaries.isEmpty {
                    EmptyState(title: "No sessions", message: "No Codex thread data from an online companion yet", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Theme.canvas)
        .navigationTitle("Sessions")
        .refreshable { await store.sync() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { await store.sync() }
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 10) {
            Circle().fill(store.devices.contains(where: { $0.onlineState == .online }) ? .green : .secondary).frame(width: 8, height: 8)
            Text("\(store.devices.filter { $0.onlineState == .online }.count) devices online").font(.subheadline.weight(.medium))
            Spacer()
            Text("\(running.count) running").font(.footnote.weight(.bold)).foregroundStyle(Theme.cobalt)
        }
        .padding(.horizontal, 14).frame(minHeight: 50).card()
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.weight(.bold)).padding(.top, 2)
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    var body: some View {
        NavigationLink { RemoteSessionView(session: session) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(session.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(statusText).font(.caption.weight(session.runtimeState == .active ? .bold : .medium)).foregroundStyle(session.runtimeState == .active ? Theme.cobalt : .secondary)
                }
                Text("\(session.deviceName) · \(session.accountAlias) · \(session.planType.uppercased())")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if session.runtimeState == .active || session.model != nil {
                    Divider()
                    Text([session.model, session.reasoningEffort, session.preview.isEmpty ? nil : session.preview].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(14).frame(minHeight: session.runtimeState == .active ? 96 : 72).card()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-\(session.key.threadId)")
        .accessibilityHint(session.capabilities.writable ? "Open remote session" : "Open read-only session")
    }

    private var statusColor: Color { session.runtimeState == .active ? .green : session.runtimeState == .systemError ? .red : .secondary }
    private var statusText: String {
        switch session.runtimeState {
        case .active: "Running"
        case .idle: "Idle"
        case .notLoaded: "Recent"
        case .systemError: "Error"
        case .readOnly: "Read-only"
        case .unavailable: "Unavailable"
        }
    }
}
