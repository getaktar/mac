import SwiftUI

/// How long a temporary (presigned) link stays valid. Seven days is the
/// longest an S3 presigned URL can last. A destination set to one copies
/// such a link after each upload instead of the public URL, which is what
/// makes it work for private buckets. The minute-long ones are for
/// confidential files: S3 can't count downloads, so a link can't be
/// single-use, but one that dies minutes after it's sent is close.
enum TemporaryLinkDuration: Int64, CaseIterable, Identifiable, Codable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case hour = 3600
    case day = 86_400
    case week = 604_800

    var id: Int64 { rawValue }

    /// For "Copy Temporary Link" menus.
    var title: LocalizedStringKey {
        switch self {
        case .fiveMinutes: return "Valid for 5 Minutes"
        case .fifteenMinutes: return "Valid for 15 Minutes"
        case .hour: return "Valid for 1 Hour"
        case .day: return "Valid for 1 Day"
        case .week: return "Valid for 7 Days"
        }
    }

    /// For the "Link" pickers, where nil is the public URL.
    static func label(_ duration: TemporaryLinkDuration?) -> String {
        switch duration {
        case nil: return String(localized: "Public")
        case .fiveMinutes: return String(localized: "5 minutes")
        case .fifteenMinutes: return String(localized: "15 minutes")
        case .hour: return String(localized: "1 hour")
        case .day: return String(localized: "24 hours")
        case .week: return String(localized: "7 days")
        }
    }
}
