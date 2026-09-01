import SwiftUI

@main
struct CodexAccountsCompanionApp: App {
    @State private var model = CompanionModel()
    var body: some Scene {
        WindowGroup { CompanionView().environment(model).frame(minWidth: 760, minHeight: 560) }
        Settings { CompanionSettingsView().environment(model).frame(width: 520, height: 360) }
    }
}

