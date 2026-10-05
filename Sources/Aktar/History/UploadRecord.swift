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

    /// "Watched: Screenshots" for an upload from a watched folder.
    var sourceLabel: String? {
        watchedFolderName.map { String(localized: "Watched: \($0)") }
    }

    /// Some destinations were saved with a schemeless base URL (e.g.
    /// "img.example.com") before URLs were normalized at resolve time;
    /// treat those as HTTPS rather than failing to load entirely.
    var publicURL: URL? {
        if let url = URL(string: publicURLString), url.scheme != nil { return url }
        return URL(string: "https://\(publicURLString)")
    }
}
