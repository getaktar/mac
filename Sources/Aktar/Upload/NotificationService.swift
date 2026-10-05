import UserNotifications

enum NotificationService {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyUploadSucceeded(filename: String, expiryDays: Int? = nil) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Uploaded")
        content.body = filename
        if let expiryDays {
            content.subtitle = String(localized: "Deletes after \(UploadExpiry.label(days: expiryDays))")
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Nothing was uploaded: the file was already in the destination, and
    /// its link was copied.
    static func notifyUploadReused(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = filename
        content.body = String(localized: "Already uploaded - copied the existing link")
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

    // MARK: - Watched folders

    /// One file from a watched folder, uploaded (or its link reused).
    static func notifyWatchedUpload(filename: String, folderName: String, reused: Bool) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Uploaded")
        content.subtitle = String(localized: "Watched: \(folderName)")
        content.body = reused ? String(localized: "\(filename) (already uploaded, link reused)") : filename
        post(content)
    }

    static func notifyWatchedBatch(count: Int, folderName: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Uploaded \(count) files from \(folderName)")
        post(content)
    }

    static func notifyWatchedFailures(count: Int, folderName: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Upload failed")
        content.body = String(localized: "\(count) files from \(folderName) couldn't be uploaded.")
        post(content)
    }

    /// A large batch is waiting for Upload or Skip.
    static func notifyLargeBatch(count: Int, folderName: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(count) new files in \(folderName)")
        content.body = String(localized: "Open Aktar from the menu bar to upload or skip them.")
        post(content)
    }

    static func notifyWatchProblem(folderName: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Watched: \(folderName)")
        content.body = message
        post(content)
    }

    static func notifyHookFailed(target: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Automation failed")
        content.body = "\(target): \(reason)"
        post(content)
    }

    /// The upload of a file deleted from a watched folder was deleted too.
    static func notifyRemoteDeleted(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Deleted \(filename) from the bucket")
        post(content)
    }

    static func notifyRemoteDeletedBatch(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Deleted \(count) files from the bucket")
        post(content)
    }

    static func notifyRemoteDeletesFailed(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(count) files couldn't be deleted from the bucket.")
        post(content)
    }

    static func notifyRemoteDeleteFailed(filename: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn't delete \(filename) from the bucket")
        content.body = reason
        post(content)
    }

    /// Thumbnails left in a bucket after they were turned off or moved
    /// to another folder, deleted at the user's request.
    static func notifyThumbnailsDeleted(destinationName: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Deleted the thumbnails of \(destinationName) from the bucket")
        post(content)
    }

    static func notifyThumbnailsDeleteFailed(destinationName: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn't delete the thumbnails of \(destinationName) from the bucket")
        content.body = reason
        post(content)
    }

    static let deleteAskCategory = "aktar.watch.delete-ask"
    static let deleteActionID = "aktar.watch.delete"
    static let keepActionID = "aktar.watch.keep"
    static let folderIDKey = "folderID"

    /// Delete from Bucket and Keep Uploaded Files on a delete ask, which
    /// answer it in the background.
    static func registerCategories() {
        let delete = UNNotificationAction(identifier: deleteActionID, title: String(localized: "Delete from Bucket"), options: [.destructive])
        let keep = UNNotificationAction(identifier: keepActionID, title: String(localized: "Keep Uploaded Files"), options: [])
        let category = UNNotificationCategory(identifier: deleteAskCategory, actions: [delete, keep], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Asks whether the uploads of files deleted from a watched folder go
    /// from the bucket too. One per folder, replaced as files join.
    static func askToDelete(names: [String], folderID: UUID, folderName: String) {
        let content = UNMutableNotificationContent()
        content.title = names.count == 1
            ? String(localized: "\(names[0]) was removed from \(folderName). Delete it from the bucket too?")
            : String(localized: "\(names.count) files were removed from \(folderName). Delete them from the bucket too?")
        content.categoryIdentifier = deleteAskCategory
        content.userInfo = [folderIDKey: folderID.uuidString]
        let request = UNNotificationRequest(identifier: deleteAskIdentifier(folderID), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The ask was answered, or its files came back.
    static func withdrawDeleteAsk(folderID: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [deleteAskIdentifier(folderID)])
        center.removePendingNotificationRequests(withIdentifiers: [deleteAskIdentifier(folderID)])
    }

    private static func deleteAskIdentifier(_ folderID: UUID) -> String {
        "aktar.watch.delete-ask.\(folderID.uuidString)"
    }

    private static func post(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
