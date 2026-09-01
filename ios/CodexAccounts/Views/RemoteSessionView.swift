import SwiftUI

struct RemoteSessionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: SessionSummary
    @State private var draft = ""
    @State private var items: [RemoteStreamItem] = []
    @State private var approval: RemoteApprovalRequest?
    @State private var isSending = false
    @State private var sharePayload: SharePayload?
    @State private var eventCursor = 0

    private var current: SessionSummary { store.sessionSummaries.first(where: { $0.id == session.id }) ?? session }
    private var host: Device? { store.devices.first { $0.id == current.key.deviceId } }
    private var hostAvailable: Bool { host?.onlineState == .online }
    private var canSend: Bool { hostAvailable && current.capabilities.writable && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationActions
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        capabilityNotice
                        ForEach(items) { item in RemoteItemView(item: item).id(item.id) }
                        if let approval { ApprovalCard(request: approval, respond: respondToApproval).id(approval.id) }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                .onChange(of: items.count) { _, _ in
                    guard let id = items.last?.id else { return }
                    if reduceMotion { proxy.scrollTo(id, anchor: .bottom) }
                    else { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            composer
        }
        .background(Theme.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .task { await runSession() }
        .onDisappear { if current.capabilities.writable { Task { await store.closeRemoteSession(current) } } }
        .sheet(item: $sharePayload) { ActivityViewController(items: [$0.text]) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 2) {
                Text(current.title).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(hostAvailable ? .green : .secondary).frame(width: 6, height: 6)
                    Text("\(current.deviceName) · \(current.accountAlias)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button { sharePayload = SharePayload(text: transcript) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button { UIPasteboard.general.string = transcript } label: { Label("Copy all", systemImage: "doc.on.doc") }
            } label: { Image(systemName: "ellipsis") }
                .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                .accessibilityLabel("More")
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var conversationActions: some View {
        HStack(spacing: 20) {
            Button { UIPasteboard.general.string = transcript } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy")
            Button { sharePayload = SharePayload(text: transcript) } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share")
            Spacer()
            if current.capabilities.interruptible, let turnID = current.activeTurnId {
                Button(role: .destructive) { Task { await interrupt(turnID) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.title3).foregroundStyle(.secondary)
        .padding(.horizontal).frame(minHeight: 40)
    }

    @ViewBuilder private var capabilityNotice: some View {
        if !hostAvailable {
            remoteNotice("Device offline", "Showing the last known session. Actions wait until the connection is restored and identity is rechecked.", "wifi.slash")
        } else if !current.capabilities.writable {
            remoteNotice("Read-only session", "This companion can read the thread, but has not proven write or takeover capability for a running desktop session.", "eye")
        } else if current.key.accountFingerprint != session.key.accountFingerprint {
            remoteNotice("Account switched", "This session belongs to a previous account and is historical read-only.", "person.crop.circle.badge.exclamationmark")
        }
    }

    private func remoteNotice(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
        } icon: { Image(systemName: symbol).foregroundStyle(Theme.cobalt) }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.accentSoft, in: .rect(cornerRadius: Theme.compactRadius, style: .continuous))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5).disabled(!hostAvailable || !current.capabilities.writable)
                .accessibilityLabel("Remote command")
            if isSending { ProgressView().controlSize(.small) }
            Button { Task { await send() } } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle).disabled(!canSend || isSending)
                .accessibilityLabel(current.capabilities.steerable ? "Steer current turn" : "Send")
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 10)
        .background(Theme.surface2, in: .capsule)
        .overlay { Capsule().stroke(Theme.track, lineWidth: 1) }
        .padding(.horizontal).padding(.bottom, 8)
    }

    private var placeholder: String {
        if !hostAvailable { return "Device offline" }
        if !current.capabilities.writable { return "This session is read-only" }
        return current.capabilities.steerable ? "Steering the current turn…" : "Continue on \(current.deviceName)…"
    }

    private var transcript: String { items.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }

    private func runSession() async {
        do {
            let state = try await store.openRemoteSession(current)
            ingest(state.items)
            approval = state.approval
            eventCursor = state.cursor
            guard !store.connections.isEmpty else { return }
            async let polling: Void = pollLoop()
            async let streaming: Void = streamLoop()
            _ = await (polling, streaming)
        } catch {
            ingest([.init(id: UUID().uuidString, kind: .error, text: error.localizedDescription, state: .failed, createdAt: .now)])
        }
    }

    private func pollLoop() async {
        var reportedConnectionError = false
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
                apply(try await store.pollRemoteSession(current, after: eventCursor))
                reportedConnectionError = false
            } catch is CancellationError { return }
            catch {
                if !reportedConnectionError {
                    ingest([.init(id: "relay-poll-error", kind: .error, text: "Live connection interrupted: \(error.localizedDescription)", state: .failed, createdAt: .now)])
                    reportedConnectionError = true
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func streamLoop() async {
        do { try await store.listenRemoteSession(current) { apply($0) } }
        catch is CancellationError { return }
        catch { /* Cursor polling remains the reconnect-safe fallback. */ }
    }

    private func apply(_ update: AppStore.RemoteState) {
        eventCursor = max(eventCursor, update.cursor)
        ingest(update.items)
        approval = update.approval
    }

    private func ingest(_ updates: [RemoteStreamItem]) {
        for update in updates {
            if let index = items.firstIndex(where: { $0.id == update.id }) {
                if update.append == true {
                    items[index].text += update.text
                    items[index].state = update.state
                    items[index].createdAt = update.createdAt
                } else {
                    items[index] = update
                }
            } else {
                items.append(update)
            }
        }
        items.sort { $0.createdAt < $1.createdAt }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""; isSending = true
        ingest([.init(id: UUID().uuidString, kind: .user, text: text, state: .completed, createdAt: .now)])
        defer { isSending = false }
        do { try await store.sendRemote(text, to: current) }
        catch { ingest([.init(id: UUID().uuidString, kind: .error, text: error.localizedDescription, state: .failed, createdAt: .now)]) }
    }

    private func interrupt(_ turnID: String) async { try? await store.interruptRemote(current, turnID: turnID) }
    private func respondToApproval(_ allowed: Bool) {
        Task {
            guard let requestID = approval?.id else { return }
            do {
                try await store.respondToApproval(current, requestID: requestID, allowed: allowed)
                approval = nil
            } catch {
                ingest([.init(id: "approval-error-\(requestID)", kind: .error, text: error.localizedDescription, state: .failed, createdAt: .now)])
            }
        }
    }
}

private struct RemoteItemView: View {
    let item: RemoteStreamItem
    var body: some View {
        switch item.kind {
        case .user:
            Text(item.text).font(.body).foregroundStyle(.white).padding(14).background(Color(light: 0x222224, dark: 0x222224), in: .rect(cornerRadius: 20, style: .continuous)).frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 68)
        case .agent:
            Text(item.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .command, .fileChange, .plan, .status:
            Label(item.text, systemImage: icon).font(.subheadline).foregroundStyle(item.state == .failed ? .red : .secondary).padding(.vertical, 4)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.red)
        }
    }
    private var icon: String { switch item.kind { case .command: "terminal"; case .fileChange: "doc.badge.gearshape"; case .plan: "list.bullet.clipboard"; default: "circle.dotted" } }
}

private struct ApprovalCard: View {
    let request: RemoteApprovalRequest
    let respond: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "checkmark.shield").font(.headline)
            Text(request.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { Button("Deny", role: .destructive) { respond(false) }.buttonStyle(.bordered); Spacer(); Button("Allow") { respond(true) }.buttonStyle(.borderedProminent) }
        }.padding(14).card(emphasized: true)
    }
}

private struct SharePayload: Identifiable { let id = UUID(); let text: String }

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
