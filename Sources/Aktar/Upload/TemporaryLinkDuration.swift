import SwiftUI

/// How long a temporary (presigned) link stays valid. Seven days is the
/// longest an S3 presigned URL can last. A destination set to one copies
/// such a link after each upload instead of the public URL, which is what
/// makes it work for private buckets.
enum TemporaryLinkDuration: Int64, CaseIterable, Identifiable, Codable {
    case hour = 3600
    case day = 86_400
    case week = 604_800

    var id: Int64 { rawValue }

    /// For "Copy Temporary Link" menus.
    var title: LocalizedStringKey {
        switch self {
        case .hour: return "Valid for 1 Hour"
        case .day: return "Valid for 1 Day"
        case .week: return "Valid for 7 Days"
        }
    }

    /// For the "Link" pickers, where nil is the public URL.
    static func label(_ duration: TemporaryLinkDuration?) -> String {
        switch duration {
        case nil: return String(localized: "Public")
        case .hour: return String(localized: "1 hour")
        case .day: return String(localized: "24 hours")
        case .week: return String(localized: "7 days")
        }
    }
}
