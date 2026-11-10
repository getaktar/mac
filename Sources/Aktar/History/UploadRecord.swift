import Foundation
import SwiftData

@Model
final class UploadRecord: Identifiable {
    @Attribute(.unique) var id: UUID
    var localFilename: String
    var objectKey: String
    var publicURLString: String
    var destinationID: UUID
    var destinationName: String
    var mimeType: String
    var byteSize: Int
    var createdAt: Date
    var remoteDeletedAt: Date?
    /// When an expiring upload is due to be deleted; nil for a normal one.
    var expiresAt: Date?
    /// SHA-256 (lowercase hex) of the bytes that were uploaded, for
    /// reusing this upload's link when the same file comes up again. Nil
    /// for uploads from before it was recorded, or when it wasn't needed.
    var contentHash: String?
    /// The watched folder this file was picked up from, and its name at the
    /// time; nil for everything uploaded by hand.
    var watchedFolderID: UUID?
    var watchedFolderName: String?
    /// When a new file was last written over this upload at its key (Replace
    /// File); nil when it never was. `createdAt` stays the first upload.
    var replacedAt: Date?
    /// The key of the share page (or gallery) this upload's link opens; nil
    /// for an upload without one (docs/share-pages.md). Several records
    /// share a gallery's key.
    var sharePageKey: String?
    /// An encrypted upload's key, base64url of the 32 raw (or password
    /// derived) bytes, so Replace File keeps the link working.
    var encryptionKey: String?
    /// A password-encrypted upload's salt, hex; nil when the key is in the
    /// link.
    var encryptionSalt: String?
    /// The file request this upload came in through, and its title then.
    var requestID: String?
    var requestTitle: String?

    /// When the bytes in the bucket were written: the last replace, or the
    /// upload. What's compared with the object's date to tell whether the
    /// object is still this upload.
    var writtenAt: Date { replacedAt ?? createdAt }

    init(
        id: UUID = UUID(),
        localFilename: String,
        objectKey: String,
        publicURLString: String,
        destinationID: UUID,
        destinationName: String,
        mimeType: String,
        byteSize: Int,
        createdAt: Date = .now,
        expiresAt: Date? = nil,
        contentHash: String? = nil,
        watchedFolderID: UUID? = nil,
        watchedFolderName: String? = nil
    ) {
        self.id = id
        self.localFilename = localFilename
        self.objectKey = objectKey
        self.publicURLString = publicURLString
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.contentHash = contentHash
        self.watchedFolderID = watchedFolderID
        self.watchedFolderName = watchedFolderName
    }

    /// "Watched: Screenshots" for an upload from a watched folder,
    /// "Request: Logs" for one sent through a file request.
    var sourceLabel: String? {
        if requestID != nil { return FileRequests.sourceLabel(title: requestTitle ?? "") }
        return watchedFolderName.map { String(localized: "Watched: \($0)") }
    }

    var isEncrypted: Bool { encryptionKey != nil }

    /// The share page's (or gallery's) own address, without a fragment.
    var sharePageURL: URL? {
        guard let sharePageKey else { return nil }
        return SharePages.pageURL(fileURL: publicURL?.absoluteString ?? publicURLString, fileKey: objectKey, pageKey: sharePageKey)
    }

    /// The fragment an encrypted upload's link carries, `k=<key>`; nil for
    /// a password, which the link never carries.
    var encryptionFragment: String? {
        guard let encryptionKey, encryptionSalt == nil else { return nil }
        return "k=" + encryptionKey
    }

    /// What copying the upload gives: its page (with the key of an
    /// encrypted one), or the file itself.
    var shareURL: URL? {
        guard let page = sharePageURL else { return publicURL }
        return Self.appendingFragment(encryptionFragment, to: page)
    }

    var shareURLString: String { shareURL?.absoluteString ?? publicURLString }

    /// `url` with `#fragment`; the short link of an encrypted upload is
    /// made without it and gets it back here.
    static func appendingFragment(_ fragment: String?, to url: URL) -> URL {
        guard let fragment, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = fragment
        return components.url ?? url
    }

    /// Some destinations were saved with a schemeless base URL (e.g.
    /// "img.example.com") before URLs were normalized at resolve time;
    /// treat those as HTTPS rather than failing to load entirely.
    var publicURL: URL? {
        if let url = URL(string: publicURLString), url.scheme != nil { return url }
        return URL(string: "https://\(publicURLString)")
    }
}
