import SwiftUI
import Observation

@MainActor @Observable
private final class PairingModel {
    enum State { case idle, creating, waiting, claimed(PairingStatus), confirmed, failed(String) }
    var state: State = .idle
    var session: PairingSession?
    var remainingSeconds = 0
    var fingerprint = ""
    private let client = RelayClient()
    private var baseURL: URL?

    func start(urlString: String) async {
        do {
            let url = try RelayURLPolicy.parse(urlString).url
            baseURL = url; state = .creating
            let value = try await client.createPairing(baseURL: url)
            session = value; state = .waiting
            await poll()
        } catch { state = .failed(error.localizedDescription) }
    }
    func poll() async {
        guard let baseURL, let session else { return }
        while Date.now < session.start.expiresAt {
            remainingSeconds = max(0, Int(session.start.expiresAt.timeIntervalSinceNow))
            do {
                let status = try await client.status(baseURL: baseURL, sessionId: session.start.sessionId, pairingAuth: session.pairingAuth)
                if status.state == "claimed" {
                    if let publicKey = status.desktopPublicKey { fingerprint = (try? CryptoBox.fingerprint(CryptoBox.sharedKey(privateKey: session.privateKey, peerPublicKey: publicKey))) ?? "" }
                    state = .claimed(status); return
                }
            } catch { state = .failed(error.localizedDescription); return }
            try? await Task.sleep(for: .seconds(2))
        }
        state = .failed("Pairing code expired")
    }
    func confirm(store: AppStore, status: PairingStatus) async {
        guard let baseURL, let session else { return }
        do {
            store.persistRelayURL()
            store.addConnection(try await client.confirm(baseURL: baseURL, session: session, status: status))
            state = .confirmed
            await store.sync()
        }
        catch { state = .failed(error.localizedDescription) }
    }
}

struct PairingView: View {
    @Environment(AppStore.self) private var store
    @State private var model = PairingModel()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Enter the 6-digit pairing code in the desktop companion to start read-only sync.").font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3").font(.title).foregroundStyle(Theme.cobalt).padding(12).background(Theme.accentSoft, in: .rect(cornerRadius: 14, style: .continuous))
                    Text("6-digit pairing code").font(.footnote).foregroundStyle(.secondary)
                    Text(code).font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(6).monospacedDigit().textSelection(.enabled).privacySensitive()
                    Text(expiryText).font(.footnote).foregroundStyle(.orange).monospacedDigit()
                }.frame(maxWidth: .infinity).padding(.vertical, 22).card(emphasized: true)
                Text("Finish on the computer").font(.title3.weight(.bold))
                PairingStep(number: 1, title: "Open the desktop companion", detail: "Choose Connect iPhone")
                PairingStep(number: 2, title: "Enter the 6-digit code", detail: "Confirm the device name and fingerprint")
                PairingStep(number: 3, title: "Approve read-only sync", detail: "OpenAI credentials stay on this computer")
                Label("Sync includes a normalized status snapshot only, not conversations or credentials.", systemImage: "lock.shield.fill")
                    .font(.caption).foregroundStyle(.secondary).padding(14).background(Theme.accentSoft, in: .rect(cornerRadius: Theme.compactRadius, style: .continuous))
                action
            }.padding()
        }.background(Theme.canvas).navigationTitle("Connect device").navigationBarTitleDisplayMode(.inline)
            .task { if case .idle = model.state { await model.start(urlString: store.relayURLString) } }
    }
    private var code: String {
        guard let raw = model.session?.start.code, raw.count == 6 else { return "— — —" }
        return "\(raw.prefix(3)) \(raw.suffix(3))"
    }
    private var expiryText: String { "Expires in \(model.remainingSeconds / 60)m \(model.remainingSeconds % 60)s" }
    @ViewBuilder private var action: some View {
        switch model.state {
        case .creating: ProgressView("Creating pairing code").frame(maxWidth: .infinity)
        case .waiting: ProgressView("Waiting for the computer").frame(maxWidth: .infinity)
        case .claimed(let status):
            VStack(spacing: 10) {
                Text("Computer: \(status.device?.name ?? "Unknown device")").font(.headline)
                Text("Fingerprint  \(model.fingerprint)").font(.system(.footnote, design: .monospaced, weight: .semibold)).textSelection(.enabled).privacySensitive()
                Button("I verified the device") { Task { await model.confirm(store: store, status: status) } }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
            }
        case .confirmed: Label("Paired", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline).frame(maxWidth: .infinity)
        case .failed(let message): VStack { Text(message).foregroundStyle(.red); Button("Generate again") { Task { await model.start(urlString: store.relayURLString) } }.buttonStyle(.borderedProminent) }.frame(maxWidth: .infinity)
        case .idle: EmptyView()
        }
    }
}

private struct PairingStep: View {
    let number: Int, title: String, detail: String
    var body: some View { HStack(spacing: 12) { Text("\(number)").font(.footnote.weight(.bold)).foregroundStyle(Theme.cobalt).frame(width: 32, height: 32).background(Theme.accentSoft, in: .circle); VStack(alignment: .leading, spacing: 2) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) } } }
}
