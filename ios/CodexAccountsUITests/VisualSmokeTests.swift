import XCTest

final class VisualSmokeTests: XCTestCase {
    func testSessionsScreenLaunchesInVisualQAMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-qaScreen", "sessions"]
        app.launchEnvironment["QUOTA_POOL_VISUAL_QA"] = "1"
        addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            if alert.buttons.count > 1 { alert.buttons.element(boundBy: 1).tap(); return true }
            return false
        }
        app.launch()
        let summary = app.descendants(matching: .any).matching(identifier: "sessions-summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
    }
}
