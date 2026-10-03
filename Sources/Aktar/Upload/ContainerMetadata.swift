import Foundation

/// Removes metadata from WebP, GIF and PNG files by dropping the chunks or
/// blocks that hold it, without touching the image data (which ImageIO
/// can't do for these: it doesn't write WebP, and re-encoding a GIF would
/// lose its animation). Used by `ImageMetadataStripper`.
enum ContainerMetadata {
    enum Failure: Error {
        /// Not laid out the way the format says; nothing is guessed.
        case malformed
    }

    // MARK: - WebP

    /// `data` without its EXIF and XMP chunks, or nil when there's nothing
    /// to remove. Under "Remove location" they only go when they hold a
    /// location: `exifHasLocation` (ImageIO's reading of the EXIF), or an
    /// XMP packet with GPS fields. EXIF in WebP is one block, so the rest
    /// of it goes along with the location. The color profile stays.
    static func webp(_ data: Data, policy: ImageMetadataPolicy, exifHasLocation: Bool) throws -> Data? {
        guard policy != .keepAll else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 12, ascii(bytes, 0, 4) == "RIFF", ascii(bytes, 8, 4) == "WEBP" else { throw Failure.malformed }
        var chunks: [(fourCC: String, range: Range<Int>)] = []
        var offset = 12
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw Failure.malformed }
            let size = Int(littleEndian32(bytes, offset + 4))
            let end = offset + 8 + size
            guard end <= bytes.count else { throw Failure.malformed }
            let padded = min(end + (size & 1), bytes.count)
            chunks.append((ascii(bytes, offset, 4), offset..<padded))
            offset = padded
        }

        let metadataChunks: Set<String> = ["EXIF", "XMP "]
        guard chunks.contains(where: { metadataChunks.contains($0.fourCC) }) else { return nil }
        if policy == .removeLocation {
            let xmpHasLocation = chunks.contains { $0.fourCC == "XMP " && containsLocation(bytes[$0.range]) }
            guard exifHasLocation || xmpHasLocation else { return nil }
        }

        var body: [UInt8] = Array("WEBP".utf8)
        for chunk in chunks where !metadataChunks.contains(chunk.fourCC) {
            var copy = Array(bytes[chunk.range])
            // The extended header's flags say which chunks follow.
            if chunk.fourCC == "VP8X", copy.count > 8 {
                copy[8] &= ~UInt8(0x08 | 0x04)
            }
            body.append(contentsOf: copy)
        }
        var output: [UInt8] = Array("RIFF".utf8)
        let size = UInt32(body.count)
        output.append(contentsOf: [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)])
        output.append(contentsOf: body)
        return Data(output)
    }

    // MARK: - GIF

    /// `data` without its XMP block (under "Remove location" only when it
    /// holds GPS fields) and, under "Remove all", its comments. Frames,
    /// colors and looping stay exactly as they are. Nil when there's
    /// nothing to remove.
    static func gif(_ data: Data, policy: ImageMetadataPolicy) throws -> Data? {
        guard policy != .keepAll else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 13, ascii(bytes, 0, 3) == "GIF" else { throw Failure.malformed }
        var position = 13
        if bytes[10] & 0x80 != 0 {
            position += 3 * (1 << (Int(bytes[10] & 0x07) + 1))
        }
        guard position <= bytes.count else { throw Failure.malformed }
        var output = Array(bytes[0..<position])
        var removed = false

        while true {
            guard position < bytes.count else { throw Failure.malformed }
            switch bytes[position] {
            case 0x3B:
                output.append(0x3B)
                return removed ? Data(output) : nil
            case 0x2C:
                guard position + 10 <= bytes.count else { throw Failure.malformed }
                var end = position + 10
                let packed = bytes[position + 9]
                if packed & 0x80 != 0 {
                    end += 3 * (1 << (Int(packed & 0x07) + 1))
                }
                // The LZW code size, then the image data's sub-blocks.
                end = try endOfSubBlocks(bytes, from: end + 1)
                output.append(contentsOf: bytes[position..<end])
                position = end
            case 0x21:
                guard position + 2 <= bytes.count else { throw Failure.malformed }
                let label = bytes[position + 1]
                let end = try endOfSubBlocks(bytes, from: position + 2)
                let block = bytes[position..<end]
                let isXMP = label == 0xFF && end >= position + 14 && bytes[position + 2] == 11
                    && ascii(bytes, position + 3, 11) == "XMP DataXMP"
                let drop: Bool
                if isXMP {
                    drop = policy == .removeAll || containsLocation(block)
                } else {
                    drop = label == 0xFE && policy == .removeAll
                }
                if drop {
                    removed = true
                } else {
                    output.append(contentsOf: block)
                }
                position = end
            default:
                throw Failure.malformed
            }
        }
    }

    /// The index just past the zero-length block that ends the sub-blocks
    /// starting at `start`.
    private static func endOfSubBlocks(_ bytes: [UInt8], from start: Int) throws -> Int {
        var position = start
        while true {
            guard position < bytes.count else { throw Failure.malformed }
            let length = Int(bytes[position])
            position += 1
            if length == 0 { return position }
            position += length
        }
    }

    // MARK: - PNG

    /// `data` without its text chunks (tEXt, zTXt, iTXt: descriptions,
    /// authors, software, XMP) and its last-changed time under "Remove all".
    /// Under "Remove location", only an XMP packet with GPS fields goes. The
    /// pixels, color profile and EXIF (which ImageIO handles) stay. Nil when
    /// there's nothing to remove.
    static func png(_ data: Data, policy: ImageMetadataPolicy) throws -> Data? {
        guard policy != .keepAll else { return nil }
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { throw Failure.malformed }
        var output = signature
        var position = 8
        var removed = false
        while position < bytes.count {
            guard position + 12 <= bytes.count else { throw Failure.malformed }
            let length = Int(bigEndian32(bytes, position))
            let end = position + 12 + length
            guard end <= bytes.count else { throw Failure.malformed }
            let type = ascii(bytes, position + 4, 4)
            let chunk = bytes[position..<end]
            let drop: Bool
            switch policy {
            case .removeAll:
                drop = ["tEXt", "zTXt", "iTXt", "tIME"].contains(type)
            case .removeLocation:
                drop = type == "iTXt" && containsLocation(chunk)
            case .keepAll:
                drop = false
            }
            if drop {
                removed = true
            } else {
                output.append(contentsOf: chunk)
            }
            position = end
            if type == "IEND" { break }
        }
        return removed ? Data(output) : nil
    }

    // MARK: - Helpers

    /// XMP keeps a location as exif:GPSLatitude and the like (and Photoshop
    /// or IPTC location fields, which name places).
    static func containsLocation<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.contains("GPS") || text.contains("LocationCreated") || text.contains("LocationShown")
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
        guard offset >= 0, offset + count <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
    }

    private static func littleEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func bigEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
