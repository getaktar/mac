import Foundation

enum DuplicateReuse {
    /// A few minutes for the Mac's clock and a multipart upload's completion.
    static let tolerance: TimeInterval = 5 * 60

    /// Whether the object in the bucket is still the one uploaded earlier:
    /// the same size, and not changed since (another device, or another
    /// app, may have put a different file at that key). Without a date it
    /// can't be told, so the file is uploaded again.
    static func isUnchanged(size: Int64, lastModified: Date?, uploadedSize: Int64, uploadedAt: Date) -> Bool {
        guard size == uploadedSize else { return false }
        guard let lastModified else { return false }
        return lastModified <= uploadedAt.addingTimeInterval(tolerance)
    }
}
