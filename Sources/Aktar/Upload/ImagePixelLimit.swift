import Foundation
import ImageIO

/// Photos bigger than this are never decoded, whatever their file size: a
/// small file can claim enormous dimensions and take all the memory when
/// its pixels are unpacked. 100 megapixels is about 400 MB.
enum ImagePixelLimit {
    static let maxPixels = 100_000_000

    static func isTooLarge(width: Int, height: Int) -> Bool {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow || pixels > maxPixels
    }

    /// The same check for the first image in `source`, from its header.
    /// One whose header doesn't say counts as too large.
    static func isTooLarge(_ source: CGImageSource) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return true }
        return isTooLarge(width: width, height: height)
    }
}
