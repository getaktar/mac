import Foundation

/// A file of a gallery, kept until its group is done.
struct GalleryEntry {
    let recordID: UUID?
    let objectKey: String
    let name: String
    let size: Int64
    let type: String
    /// The bucket thumbnail's key, when one was saved.
    let thumbnailKey: String?
    let expiresAt: Date?
    /// A new upload (not a reused link), whose record gets the gallery.
    let isNew: Bool
}

/// What an upload's link is besides the file: its share page, and for an
/// encrypted upload the key.
struct ShareOutcome {
    let pageKey: String
    /// The file's own link (public, or presigned with the page's).
    let fileLink: URL
    /// The link's fragment (`k=...`), never sent to a shortener.
    let fragment: String?
    let keys: ShareEncryption.KeyMaterial?

    var isEncrypted: Bool { keys != nil }
}

/// Share pages, galleries and encrypted links in the upload pipeline
/// (docs/share-pages.md).
extension UploadManager {
    static let pageTemplate = SharePages.bundledTemplate()

    /// The page's language: the app's UI language.
    static var pageLanguage: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    // MARK: - What an upload gets

    /// Whether a job gets a share page of its own: a file (or a folder as
    /// a ZIP) uploaded by hand to a key Aktar makes, on a destination with
    /// Share Page on. Not a watched folder's file, a file of a group (it's
    /// in the gallery), a file request's, an exact key, or one sent by the
    /// local API or Shortcuts. Replace File keeps the page the upload had.
    func wantsOwnPage(_ job: UploadJob, destination: DestinationConfig) -> Bool {
        // A link copied before the upload finished already says.
        if let early = job.earlyLink { return early.pageKey != nil }
        if job.input.replacing != nil { return replacedPageKey(of: job) != nil }
        return destination.writesSharePages && job.input.watch == nil && job.input.group == nil
            && job.input.request == nil && job.input.objectKey == nil && job.input.folderKey == nil
            && !job.input.isUnattended && !job.isWaitedFor
    }

    /// The page a replaced upload had (not a gallery's, which isn't
    /// rewritten in v1).
    func replacedPageKey(of job: UploadJob) -> String? {
        guard let id = job.input.replacing?.recordID, let record = repository.record(id: id),
              let key = record.sharePageKey, !key.hasSuffix(".gallery.html"), !record.isEncrypted else { return nil }
        return key
    }

    /// The key an encrypted upload is sealed with, or nil when the upload
    /// isn't encrypted. A write to an exact key keeps the encryption of the
    /// upload it replaces (Replace File, a watched folder keeping its
    /// link); a new upload to an encrypted destination gets a new key,
    /// from the password typed for it, or in the link when nobody could be
    /// asked.
    func encryptionKeys(for job: UploadJob, destination: DestinationConfig) async -> ShareEncryption.KeyMaterial? {
        if let key = job.input.objectKey {
            let record = job.input.replacing?.recordID.flatMap { repository.record(id: $0) }
                ?? repository.records(key: key, destinationID: destination.id).max { $0.writtenAt < $1.writtenAt }
            guard let record, let encoded = record.encryptionKey,
                  let raw = ShareEncryption.base64URLDecoded(encoded), raw.count == ShareEncryption.keyLength else { return nil }
            return ShareEncryption.KeyMaterial(key: raw, salt: record.encryptionSalt.flatMap { ShareEncryption.data(hex: $0) })
        }
        guard destination.encryption != nil, job.input.folderKey == nil else { return nil }
        if let keys = job.encryptionKeys { return keys }
        let keys: ShareEncryption.KeyMaterial
        if destination.encryption == .password, let password = job.password, !password.isEmpty {
            keys = await Task.detached(priority: .userInitiated) { ShareEncryption.KeyMaterial.fromPassword(password) }.value
        } else {
            keys = .newLinkKey()
        }
        job.password = nil
        job.encryptionKeys = keys
        return keys
    }

    /// Asks for each file's password before files go to a destination that
    /// encrypts with one. A file whose prompt is cancelled (or left empty)
    /// isn't uploaded. Uploads nobody is there for get the key in the link.
    func askPasswords(_ inputs: [UploadInput], for destination: DestinationConfig) -> [(UploadInput, String?)] {
        guard destination.encryption == .password else { return inputs.map { ($0, nil) } }
        return inputs.compactMap { input in
            guard input.watch == nil, input.request == nil, !input.isUnattended,
                  input.objectKey == nil, input.folderKey == nil, input.replacing == nil else { return (input, nil) }
            guard let password = PasswordPrompt.ask(filename: input.originalFilename) else {
                TempFiles.removeIfOwned(input.fileURL)
                return nil
            }
            return (input, password)
        }
    }

    /// The `syntax` in an encrypted text file's metadata: its language,
    /// left out for plain text.
    nonisolated static func encryptedSyntax(_ filename: String) -> String? {
        let syntax = SharePages.syntax(forFilename: filename)
        return syntax == "text" ? nil : syntax
    }

    // MARK: - Links

    /// The link to `key`: its public URL, or a presigned one when the
    /// destination copies temporary links, with when it stops working.
    func link(toKey key: String, destination: DestinationConfig, provider: S3Provider) async throws -> (URL, Date?) {
        if let duration = destination.temporaryLink,
           let signed = try? await provider.temporaryURL(for: key, expiresIn: duration.rawValue) {
            return (signed, Date.now.addingTimeInterval(TimeInterval(duration.rawValue)))
        }
        guard let url = PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: key) else {
            throw StorageError.invalidPublicBaseURL
        }
        return (url, nil)
    }

    /// What's copied for an upload with a share page: the page link as
    /// "Copy as" says (images, videos and audio embed the file), or for an
    /// encrypted one always the plain link, with its key after any short
    /// link.
    func shareText(link: URL, shortURL: URL?, filename: String, destination: DestinationConfig, share: ShareOutcome) -> String {
        if share.isEncrypted {
            return UploadRecord.appendingFragment(share.fragment, to: shortURL ?? link).absoluteString
        }
        return OutputFormatter.format(
            publicURL: link,
            shortURL: shortURL,
            mode: outputMode(for: destination),
            filename: filename,
            customTemplate: customTemplate,
            fileURL: share.fileLink
        )
    }

    // MARK: - Writing pages

    /// The `expires` of a page: the earliest of Delete after and a
    /// temporary link running out.
    static func pageExpiry(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.min()
    }

    func writePage(_ page: SharePage, key: String, provider: S3Provider) async throws {
        guard let template = Self.pageTemplate else {
            throw StorageError.unknown(String(localized: "The share page template is missing from Aktar."))
        }
        try await SharePagePublisher.write(page, key: key, provider: provider, template: template)
    }

    /// The page of one file (kind `file` or `text`), or of an encrypted one.
    func singlePage(
        filename: String,
        fileLink: URL,
        size: Int64,
        contentType: String,
        thumbnailLink: URL?,
        text: String?,
        expires: Date?,
        encrypted: (url: URL, size: Int64, password: Bool)?
    ) -> SharePage {
        if let encrypted {
            return SharePage(
                kind: .encrypted, lang: Self.pageLanguage, created: .now, expires: expires,
                encrypted: .init(url: encrypted.url.absoluteString, size: encrypted.size, password: encrypted.password)
            )
        }
        let type = SharePages.bareType(contentType)
        let thumb = thumbnailLink?.absoluteString
        let file = SharePage.File(
            name: filename, url: fileLink.absoluteString, size: size, type: type, thumb: thumb,
            ogImage: SharePages.ogImage(type: type, size: size, url: fileLink.absoluteString, thumb: thumb)
        )
        if let text {
            return SharePage(kind: .text, lang: Self.pageLanguage, created: .now, expires: expires, files: [file],
                             text: text, syntax: SharePages.syntax(forFilename: filename))
        }
        return SharePage(kind: .file, lang: Self.pageLanguage, created: .now, expires: expires, files: [file])
    }

    /// The link of the bucket thumbnail at `key` (presigned like the page
    /// on a temporary-link destination).
    func thumbnailLink(key: String?, destination: DestinationConfig, provider: S3Provider) async -> URL? {
        guard let key else { return nil }
        return try? await link(toKey: key, destination: destination, provider: provider).0
    }

    // MARK: - Galleries

    /// Writes a group's gallery once its last file is done and copies its
    /// one link. A group where only one file made it gets that file's own
    /// page instead; one where none did copies nothing.
    func finishGallery(_ group: UploadGroup, entries: [GalleryEntry], destination: DestinationConfig, action: UploadAction?) async {
        guard let first = entries.first else { return }
        do {
            let provider = S3Provider(config: destination, credentials: try KeychainService.load(for: destination.id))
            let single = entries.count == 1
            let pageKey = single ? SharePages.pageKey(forFileKey: first.objectKey) : SharePages.galleryKey(forFirstFileKey: first.objectKey)
            var files: [SharePage.File] = []
            var expiries: [Date?] = []
            for entry in entries {
                let (url, signedUntil) = try await link(toKey: entry.objectKey, destination: destination, provider: provider)
                let thumb = await thumbnailLink(key: entry.thumbnailKey, destination: destination, provider: provider)?.absoluteString
                files.append(SharePage.File(
                    name: entry.name, url: url.absoluteString, size: entry.size, type: entry.type, thumb: thumb,
                    ogImage: SharePages.ogImage(type: entry.type, size: entry.size, url: url.absoluteString, thumb: thumb)
                ))
                expiries.append(entry.expiresAt)
                expiries.append(signedUntil)
            }
            let (pageLink, pageSignedUntil) = try await link(toKey: pageKey, destination: destination, provider: provider)
            expiries.append(pageSignedUntil)
            let page = SharePage(
                kind: single ? .file : .gallery, lang: Self.pageLanguage, created: .now,
                expires: Self.pageExpiry(expiries), files: files
            )
            try await writePage(page, key: pageKey, provider: provider)
            for entry in entries where entry.isNew {
                if let id = entry.recordID, let record = repository.record(id: id) { record.sharePageKey = pageKey }
            }
            try? repository.modelContext.save()
            if action?.isUndoing == true {
                try? await provider.delete(objectKey: pageKey)
                return
            }
            let title = single ? first.name : "\(first.name) +\(entries.count - 1)"
            let text: String
            if single {
                text = OutputFormatter.format(publicURL: pageLink, mode: outputMode(for: destination), filename: first.name,
                                              customTemplate: customTemplate, fileURL: URL(string: files[0].url))
            } else {
                text = OutputFormatter.formatGallery(link: pageLink, title: title, mode: outputMode(for: destination))
            }
            if let action { copy(text, in: action) } else { ClipboardService.copy(text) }
            if showsSuccessNotifications {
                let identifier = "aktar.upload.group.\(group.id.uuidString)"
                let summary = entries.count == group.count
                    ? String(localized: "\(group.name) (\(group.count) files)")
                    : String(localized: "\(group.name) (\(entries.count) of \(group.count) files)")
                NotificationService.notifyUploadSucceeded(filename: single ? first.name : summary, identifier: identifier, actionID: action?.id)
                action?.notificationIDs.insert(identifier)
            }
            if let action { extendUndo(action) }
            closePanelIfWanted()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NotificationService.notifySharePageFailed(filename: group.name, reason: reason)
        }
    }

    // MARK: - Deleting pages

    /// After an upload's file was deleted: its page goes too, unless
    /// another history entry still points at it (a gallery's other files).
    /// A page that's already gone is fine.
    func deletePageIfUnused(of record: UploadRecord, provider: S3Provider) async {
        guard let key = record.sharePageKey else { return }
        let others = repository.records(sharePageKey: key, destinationID: record.destinationID).filter { $0.id != record.id }
        await SharePagePublisher.delete(pageKey: key, stillUsed: !others.isEmpty, provider: provider)
    }
}
