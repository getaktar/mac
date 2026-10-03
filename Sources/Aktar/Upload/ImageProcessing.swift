import Foundation

/// Conversion, recompression and resizing of photos before they're
/// uploaded. Set per destination; nil there leaves photos as they are.
/// The same JSON shape is used by the Windows and mobile apps.
struct ImageProcessing: Codable, Hashable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case original
        case webp
        case avif

        var id: String { rawValue }
    }

    var format: Format = .original
    /// 90, 80 or 65 (percent); nil doesn't recompress.
    var quality: Int?
    /// Longest side in pixels; nil keeps the size. Never upscales.
    var maxLongEdge: Int?

    static let qualityOptions = [90, 80, 65]
    static let sizeOptions = [3840, 2560, 1920, 1280, 1024]

    var isOff: Bool { format == .original && quality == nil && maxLongEdge == nil }

    init(format: Format = .original, quality: Int? = nil, maxLongEdge: Int? = nil) {
        self.format = format
        self.quality = quality
        self.maxLongEdge = maxLongEdge
    }

    /// Lenient, so a value written by a newer app (or another platform)
    /// doesn't make the whole destination list unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? container.decodeIfPresent(String.self, forKey: .format)).flatMap { $0.flatMap(Format.init(rawValue:)) } ?? .original
        quality = try? container.decodeIfPresent(Int.self, forKey: .quality)
        maxLongEdge = try? container.decodeIfPresent(Int.self, forKey: .maxLongEdge)
    }

    static func qualityLabel(_ quality: Int?) -> String {
        switch quality {
        case nil: return String(localized: "Off")
        case 90: return String(localized: "Light (90%)")
        case 80: return String(localized: "Medium (80%)")
        case 65: return String(localized: "Strong (65%)")
        case let quality?: return "\(quality)%"
        }
    }

    static func sizeLabel(_ maxLongEdge: Int?) -> String {
        guard let maxLongEdge else { return String(localized: "Off") }
        return String(localized: "Longest side \(String(maxLongEdge)) px")
    }
}

extension ImageProcessing.Format {
    var label: String {
        switch self {
        case .original: return String(localized: "Keep Original")
        case .webp: return "WebP"
        case .avif: return "AVIF"
        }
    }
}
