import SwiftUI

struct RootView: View {
    private var qaScreen: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-qaScreen"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }

    @ViewBuilder
    var body: some View {
        if qaScreen == "sessions" { NavigationStack { SessionsView() } }
        else if qaScreen == "usage" { NavigationStack { DeviceUsageView() } }
        else if qaScreen == "resets" { NavigationStack { ResetsView() } }
        else if qaScreen == "remote" { NavigationStack { RemoteQAScreen() } }
        else {
            TabView {
                Tab("Hub", systemImage: "command") { NavigationStack { AccountsView() } }
                Tab("Sessions", systemImage: "bubble.left.and.bubble.right") { NavigationStack { SessionsView() } }
                Tab("Resets", systemImage: "arrow.counterclockwise") { NavigationStack { ResetsView() } }
                Tab("Activity", systemImage: "chart.bar.xaxis") { NavigationStack { ActivityView() } }
                Tab("Settings", systemImage: "slider.horizontal.3") { NavigationStack { SettingsView() } }
            }
            .tint(Theme.cobalt)
        }
    }
}

#if DEBUG
private struct RemoteQAScreen: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let session = store.sessionSummaries.first { RemoteSessionView(session: session) }
        else { ProgressView("Loading session…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas) }
    }
}
#endif
