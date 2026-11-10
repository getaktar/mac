import UserNotifications

enum NotificationService {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `identifier` replaces an earlier notification of the same upload
    /// ("still uploading"). With `actionID`, it has Undo; see
    /// `UploadManager.undo`.
    static func notifyUploadSucceeded(filename: String, expiryDays: Int? = nil, identifier: String? = nil, actionID: UUID? = nil, uploadID: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Uploaded")
        content.body = filename
        if let expiryDays {
            content.subtitle = String(localized: "Deletes after \(UploadExpiry.label(days: expiryDays))")
        }
        offerUndo(content, actionID: actionID, uploadID: uploadID)
        post(content, identifier: identifier)
    }

    /// Nothing was uploaded: the file was already in the destination, and
    /// its link was copied.
    static func notifyUploadReused(filename: String, identifier: String? = nil, actionID: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = filename
        content.body = String(localized: "Already uploaded - copied the existing link")
        offerUndo(content, actionID: actionID, uploadID: nil)
        post(content, identifier: identifier)
    }

    // MARK: - Instant link, offline queue and Undo

    /// The link was copied before the upload finished, and it's still
    /// going after a moment.
    static func notifyLinkCopiedUploading(filename: String, identifier: String, actionID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Link copied")
        content.subtitle = filename
        content.body = String(localized: "Still uploading. The link works once the upload is done.")
        offerUndo(content, actionID: actionID, uploadID: nil)
        post(content, identifier: identifier)
    }

    /// An upload is waiting for the network; it goes on when it's back.
    static func notifyWaitingForNetwork(filename: String, linkCopied: Bool, identifier: String, actionID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Waiting for a connection")
        content.subtitle = filename
        content.body = linkCopied
            ? String(localized: "The link is copied. The file uploads when you\u{2019}re back online, and the link works from then on.")
            : String(localized: "The file uploads when you\u{2019}re back online.")
        offerUndo(content, actionID: actionID, uploadID: nil)
        post(content, identifier: identifier)
    }

    /// A clash in the bucket gave the upload another key after its link
    /// was copied; the new link was copied in its place.
    static func notifyLinkChanged(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = filename
        content.body = String(localized: "The link changed while uploading. The new link is copied; the one copied before doesn\u{2019}t work.")
        post(content)
    }

    static func notifyUndone(names: [String]) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Upload undone")
        content.body = names.count == 1 ? names[0] : String(localized: "\(names.count) files")
        post(content)
    }

    static let uploadDoneCategory = "aktar.upload.done"
    static let undoActionID = "aktar.upload.undo"
    static let actionIDKey = "actionID"

    private static func offerUndo(_ content: UNMutableNotificationContent, actionID: UUID?, uploadID: UUID?) {
        guard let actionID else { return }
        content.categoryIdentifier = uploadDoneCategory
        var info: [String: String] = [actionIDKey: actionID.uuidString]
        if let uploadID { info[uploadIDKey] = uploadID.uuidString }
        content.userInfo = info
    }

    static func remove(identifier: String) {
        remove(identifiers: [identifier])
    }

    static func remove(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// The file is up but its share page couldn't be written; the file's
    /// own link was copied instead.
    static func notifySharePageFailed(filename: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "The share page couldn\u{2019}t be written")
        content.subtitle = filename
        content.body = String(localized: "The file\u{2019}s own link was copied instead. \(reason)")
        post(content)
    }

    /// Files arrived through a file request and are in history now.
    static func notifyRequestReceived(count: Int, title: String) {
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? String(localized: "Received 1 file") : String(localized: "Received \(count) files")
        content.body = FileRequests.sourceLabel(title: title)
        content.userInfo = [openLibraryKey: "1"]
        post(content)
    }

    static let openLibraryKey = "openLibrary"

    /// A file was written over an upload; its link stays the same.
    static func notifyReplaced(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = filename
        content.body = String(localized: "Replaced - the link stays the same and is copied")
        post(content)
    }

    static func notifyPurgeFailed(filename: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "The file was replaced, but Cloudflare\u{2019}s cache couldn\u{2019}t be cleared")
        content.body = "\(filename): \(reason)"
        post(content)
    }

    /// `linkCopied`: the upload's link was copied already, and won't work
    /// until it's uploaded (Retry in the panel).
    static func notifyUploadFailed(filename: String, reason: String, linkCopied: Bool = false, identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Upload failed")
        if linkCopied {
            content.subtitle = String(localized: "The copied link won\u{2019}t work until the file is uploaded.")
        }
        content.body = "\(filename): \(reason)"
        post(content, identifier: identifier)
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

    // MARK: - Short links

    static let shortLinkFailedCategory = "aktar.short-link.failed"
    static let retryShortLinkActionID = "aktar.short-link.retry"
    static let uploadIDKey = "uploadID"

    /// Rule 3: the short link couldn't be made, so the original link was
    /// copied. Retry makes one and copies it.
    static func notifyShortLinkFailed(filename: String, reason: String, uploadID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = filename
        content.subtitle = String(localized: "Short link couldn't be created. The original link was copied instead.")
        content.body = reason
        content.categoryIdentifier = shortLinkFailedCategory
        content.userInfo = [uploadIDKey: uploadID.uuidString]
        post(content)
    }

    static func notifyShortLinkCopied(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = filename
        content.body = String(localized: "Short link created and copied")
        post(content)
    }

    /// Rule 5: the file is gone, a short link to it may not be.
    static func notifyShortLinkCleanupFailed(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "File deleted \u{2713} / Short link cleanup failed \u{26A0}")
        content.body = String(localized: "\(filename): the short link may still exist.")
        post(content)
    }

    static let deleteAskCategory = "aktar.watch.delete-ask"
    static let deleteActionID = "aktar.watch.delete"
    static let keepActionID = "aktar.watch.keep"
    static let folderIDKey = "folderID"

    /// Delete from Bucket and Keep Uploaded Files on a delete ask, which
    /// answer it in the background, Retry on a failed short link, and Undo
    /// on an upload.
    static func registerCategories() {
        let delete = UNNotificationAction(identifier: deleteActionID, title: String(localized: "Delete from Bucket"), options: [.destructive])
        let keep = UNNotificationAction(identifier: keepActionID, title: String(localized: "Keep Uploaded Files"), options: [])
        let category = UNNotificationCategory(identifier: deleteAskCategory, actions: [delete, keep], intentIdentifiers: [])
        let retry = UNNotificationAction(identifier: retryShortLinkActionID, title: String(localized: "Retry"), options: [])
        let shortLink = UNNotificationCategory(identifier: shortLinkFailedCategory, actions: [retry], intentIdentifiers: [])
        let undo = UNNotificationAction(identifier: undoActionID, title: String(localized: "Undo"), options: [.destructive])
        let uploadDone = UNNotificationCategory(identifier: uploadDoneCategory, actions: [undo], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, shortLink, uploadDone])
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

    private static func post(_ content: UNMutableNotificationContent, identifier: String? = nil) {
        let request = UNNotificationRequest(identifier: identifier ?? UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
