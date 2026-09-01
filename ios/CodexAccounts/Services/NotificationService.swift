import Foundation
import UserNotifications

enum NotificationService {
    static func reschedule(snapshot: Snapshot?) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-qaScreen") || ProcessInfo.processInfo.environment["QUOTA_POOL_VISUAL_QA"] == "1" { return }
        #endif
        guard let snapshot else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("codex-accounts-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        if UserDefaults.standard.object(forKey: "quotaNotifications") as? Bool ?? true {
            for quota in snapshot.rateLimitWindows {
                await add(center, id: "codex-accounts-quota-\(quota.id)", title: "\(quota.displayName) resets soon", body: "Quota restores in 15 minutes", date: quota.resetsAt.addingTimeInterval(-900))
            }
        }
        if UserDefaults.standard.object(forKey: "creditNotifications") as? Bool ?? true {
            for credit in snapshot.resetCreditSummaries.flatMap({ $0.credits ?? [] }) where credit.status == "available" {
                if let expiresAt = credit.expiresAt { await add(center, id: "codex-accounts-credit-\(credit.id)", title: "Saved rate-limit reset expiring soon", body: credit.title ?? "A reset expires in 1 day", date: expiresAt.addingTimeInterval(-86400)) }
            }
        }
    }
    private static func add(_ center: UNUserNotificationCenter, id: String, title: String, body: String, date: Date) async {
        guard date > .now else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
}
