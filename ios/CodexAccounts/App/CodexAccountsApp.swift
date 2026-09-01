import SwiftUI

@main
struct CodexAccountsApp: App {
    @State private var store = AppStore()
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
                .task { await store.bootstrap(); await store.runForegroundRefresh() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.sync() } } }
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { switch self { case .system: "Match system"; case .light: "Light"; case .dark: "Dark" } }
    var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}
