import SwiftUI

struct DeviceSelectorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.devices.isEmpty { EmptyState(title: "No devices", message: "Connect a Mac or Windows companion", systemImage: "laptopcomputer.slash") }
                    ForEach(store.devices) { device in
                        Button {
                            store.selectedDeviceID = device.id
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: device.platform == .windows ? "desktopcomputer" : "laptopcomputer")
                                    .font(.title2).foregroundStyle(Theme.cobalt).frame(width: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name).font(.headline).foregroundStyle(.primary)
                                    Text(device.osVersion).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Circle().fill(device.onlineState == .online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                                if store.selectedDeviceID == device.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.cobalt) }
                            }.padding(16).frame(minHeight: 76).card(emphasized: store.selectedDeviceID == device.id)
                        }.buttonStyle(.plain)
                    }
                }.padding()
            }.background(Theme.canvas).navigationTitle("Devices")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } }
                    ToolbarItem(placement: .primaryAction) { Button { showingPairing = true } label: { Image(systemName: "plus") }.buttonStyle(.borderedProminent) }
                }
                .navigationDestination(isPresented: $showingPairing) { PairingView() }
        }
    }
}

