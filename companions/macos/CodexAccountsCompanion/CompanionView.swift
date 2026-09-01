import SwiftUI

struct CompanionView: View {
    @Environment(CompanionModel.self) private var model
    @State private var selection: SidebarItem? = .overview
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "gauge.with.dots.needle.67percent").tag(SidebarItem.overview)
                Label("Local accounts", systemImage: "person.2").tag(SidebarItem.profiles)
                Label("Connect iPhone", systemImage: "iphone.and.arrow.forward").tag(SidebarItem.pairing)
            }.navigationTitle("Quota Pool")
        } detail: {
            switch selection ?? .overview { case .overview: OverviewPane(); case .profiles: ProfilesPane(); case .pairing: PairingPane() }
        }
        .alert("Notice", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") {} } message: { Text(model.errorMessage ?? "") }
        .task { await model.runRelayConnection() }
    }
}

private enum SidebarItem: Hashable { case overview, profiles, pairing }

private struct OverviewPane: View {
    @Environment(CompanionModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Overview").font(.largeTitle.bold())
            GroupBox {
                LabeledContent("Devices", value: model.device.name)
                LabeledContent("Status", value: model.status)
                LabeledContent("Local profiles", value: "\(model.profiles.count)")
                LabeledContent("iPhone", value: model.pairing == nil ? "Not connected" : "Connected")
            }
            HStack {
                Button("Sync now", systemImage: "arrow.clockwise") { Task { await model.sync() } }.buttonStyle(.borderedProminent).disabled(model.isWorking || model.pairing == nil)
                Button("Record a confirmed global rate-limit reset", systemImage: "checkmark.seal") { model.recordVerifiedGlobalReset() }
                if model.isWorking { ProgressView() }
            }
            Text("OpenAI credentials stay on this computer. Snapshots and Remote Session content are encrypted before they reach the relay.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(28).frame(maxWidth: 720, alignment: .leading).navigationTitle("Overview")
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    if model.pairing != nil, !model.isWorking { await model.sync() }
                }
            }
            .task {
                while !Task.isCancelled {
                    await model.pollRemoteCommands()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
}

private struct ProfilesPane: View {
    @Environment(CompanionModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Local accounts").font(.largeTitle.bold()); Spacer(); Button("Add", systemImage: "plus") { model.addProfile() }.buttonStyle(.borderedProminent) }
            Text("Each profile is one local Codex login. Leave CODEX_HOME empty to use the default location.").foregroundStyle(.secondary)
            List {
                ForEach($model.profiles) { $profile in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { TextField("Alias (iPhone assigns a name if empty)", text: $profile.alias).font(.headline); Toggle("Current", isOn: $profile.isCurrent).toggleStyle(.checkbox) }
                        TextField("CODEX_HOME (optional)", text: $profile.codexHome)
                        TextField("Codex CLI path", text: $profile.codexBinary)
                    }.padding(.vertical, 8)
                }.onDelete(perform: model.removeProfiles)
            }
            Button("Save profiles") { model.saveSettings() }.buttonStyle(.borderedProminent)
        }.padding(28).navigationTitle("Local accounts")
    }
}

private struct PairingPane: View {
    @Environment(CompanionModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect iPhone").font(.largeTitle.bold())
            Text("Generate a 6-digit pairing code on iPhone under Devices → Connect Device. The code expires in 5 minutes.")
                .foregroundStyle(.secondary)
            TextField("000000", text: $model.pairingCode).font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit().textFieldStyle(.roundedBorder).frame(width: 240)
            if !model.pairingFingerprint.isEmpty { Text("Fingerprint  \(model.pairingFingerprint)").font(.system(.headline, design: .monospaced)).textSelection(.enabled) }
            HStack { Button("Connect", systemImage: "link") { Task { await model.pair() } }.buttonStyle(.borderedProminent).disabled(model.pairingCode.filter(\.isNumber).count != 6 || model.isWorking); if model.isWorking { ProgressView() } }
            GroupBox("Encrypted sync") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Reads the locally installed Codex App Server", systemImage: "checkmark.circle")
                    Label("Does not upload OpenAI credentials or plaintext conversations", systemImage: "checkmark.circle")
                    Label("Snapshots, commands, and Remote Session content are encrypted before relay upload", systemImage: "checkmark.circle")
                    Label("Remote Session can resume, prompt, steer, interrupt, and handle approvals on paired sessions", systemImage: "checkmark.circle")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }.padding(28).frame(maxWidth: 720, alignment: .leading).navigationTitle("Connect iPhone")
    }
}

struct CompanionSettingsView: View {
    @Environment(CompanionModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            TextField("Relay URL", text: $model.relayURL)
            Text("Public relays must use HTTPS. http:// is allowed only for this computer or a LAN IP.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack { Spacer(); Button("Save") { model.saveSettings() }.buttonStyle(.borderedProminent) }
        }.padding().navigationTitle("Sync settings")
    }
}
