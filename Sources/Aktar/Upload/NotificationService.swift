import UserNotifications

enum NotificationService {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyUploadSucceeded(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Uploaded")
        content.body = filename
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyUploadFailed(filename: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Upload failed")
        content.body = "\(filename): \(reason)"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
