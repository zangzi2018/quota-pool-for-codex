import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        List {
            Section("Devices & accounts") {
                NavigationLink { DeviceSelectorView() } label: { SettingsLabel(title: "Devices", subtitle: "\(store.devices.count) devices, \(store.devices.filter { $0.onlineState == .online }.count) online", icon: "laptopcomputer.and.iphone") }
                NavigationLink { AliasSettingsView() } label: { SettingsLabel(title: "Account aliases", subtitle: "\(Set(store.snapshots.flatMap(\.accounts).compactMap(\.alias)).count) accounts named", icon: "person.text.rectangle") }
                NavigationLink { RenewalListView() } label: { SettingsLabel(title: "Renewal date", subtitle: "Set manually", icon: "calendar") }
            }
            Section("Alerts") {
                SettingsToggle(title: "Quota reset reminder", subtitle: "15 minutes before the next restore", key: "quotaNotifications", icon: "bell")
                SettingsToggle(title: "Saved rate-limit reset expiry", subtitle: "Remind 1 day ahead", key: "creditNotifications", icon: "hourglass")
            }
            Section("Preferences & privacy") {
                NavigationLink { AppearanceSettingsView() } label: { SettingsLabel(title: "Appearance", subtitle: "Match system", icon: "circle.lefthalf.filled") }
                NavigationLink { PrivacySyncView() } label: { SettingsLabel(title: "Privacy & sync", subtitle: "End-to-end encrypted sync", icon: "lock.shield") }
                NavigationLink { AboutView() } label: { SettingsLabel(title: "About", subtitle: "Quota Pool 1.0", icon: "info.circle") }
            }
        }.listStyle(.insetGrouped).navigationTitle("Settings")
    }
}

private struct SettingsLabel: View {
    let title, subtitle, icon: String
    var body: some View { Label { VStack(alignment: .leading, spacing: 2) { Text(title); Text(subtitle).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: icon).foregroundStyle(Theme.cobalt).frame(width: 28) }.frame(minHeight: 46) }
}
private struct SettingsToggle: View {
    @Environment(AppStore.self) private var store
    let title, subtitle, key, icon: String
    @AppStorage private var isOn: Bool
    init(title: String, subtitle: String, key: String, icon: String) { self.title = title; self.subtitle = subtitle; self.key = key; self.icon = icon; _isOn = AppStorage(wrappedValue: true, key) }
    var body: some View { Toggle(isOn: $isOn) { SettingsLabel(title: title, subtitle: subtitle, icon: icon) }.onChange(of: isOn) { _, _ in Task { await NotificationService.reschedule(snapshot: store.selectedSnapshot) } } }
}

private struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    var body: some View { Form { Picker("Appearance", selection: $appearance) { ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) } }.pickerStyle(.inline) } .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline) }
}

private struct PrivacySyncView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Relay") {
                TextField("https://relay.example.com", text: $store.relayURLString).textInputAutocapitalization(.never).keyboardType(.URL)
                Button("Save and sync") { store.persistRelayURL(); Task { await store.sync() } }
                Text("Public relays must use HTTPS. Cleartext HTTP is allowed only for loopback or LAN IPs. Snapshots, commands, and Remote Session content stay end-to-end encrypted through the relay.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Label("OpenAI credentials stay on the paired computer", systemImage: "checkmark.shield")
                Label("Snapshots and Remote Session content are end-to-end encrypted", systemImage: "lock.fill")
                Label("HTTPS is required for public relays", systemImage: "lock.shield")
                Label("Quota and saved-reset controls are read-only", systemImage: "eye")
            }
        }.navigationTitle("Privacy & sync").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AliasSettingsView: View {
    @Environment(AppStore.self) private var store
    private var accounts: [Account] { Array(Dictionary(grouping: store.snapshots.flatMap(\.accounts), by: \.id).values.compactMap { $0.first }).sorted { $0.email < $1.email } }
    var body: some View {
        List(accounts) { account in
            VStack(alignment: .leading, spacing: 4) {
                TextField("Alias", text: .init(get: { store.snapshots.flatMap(\.accounts).first(where: { $0.id == account.id })?.alias ?? "" }, set: { store.updateAlias(accountID: account.id, alias: $0) }))
                Text(account.email).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }.navigationTitle("Account aliases")
    }
}
private struct RenewalListView: View {
    @Environment(AppStore.self) private var store
    var body: some View { List(Array(Dictionary(grouping: store.snapshots.flatMap(\.accounts), by: \.id).values.compactMap { $0.first }), id: \.id) { account in NavigationLink { RenewalEditorView(account: account) } label: { VStack(alignment: .leading) { Text(account.displayName); Text(account.renewalAt?.formatted(.dateTime.year().month().day()) ?? "Not set").font(.caption).foregroundStyle(.secondary) } } }.navigationTitle("Renewal date") }
}
private struct AboutView: View {
    var body: some View { List { Section { LabeledContent("Product", value: "Quota Pool"); LabeledContent("Version", value: "1.0"); LabeledContent("Protocol", value: "Snapshot v1") }; Section { Text("A personal Codex account and paired Remote Session console. Quota/reset management is read-only. Not an official OpenAI product.") } }.navigationTitle("About") }
}
