import AVFoundation
import Foundation

/// The video side of a destination's Image metadata setting: QuickTime and
/// MPEG-4 videos (.mov, .mp4, .m4v) from a phone carry where they were
/// recorded. They're copied without re-encoding (a passthrough export)
/// and without that metadata: the location under "Remove location", all
/// of it under "Remove all". If that can't be done the upload stops, the
/// same as for a photo that can't be cleaned.
enum VideoMetadataStripper {
    static let extensions: Set<String> = ["mov", "mp4", "m4v"]

    static func isVideo(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// A copy of the video at `url` without the metadata `policy` removes,
    /// or nil when there's nothing to remove (or it's not a video). The
    /// caller deletes the copy with `ImageMetadataStripper.removeCopy`.
    @concurrent
    static func strippedCopy(of url: URL, policy: ImageMetadataPolicy) async throws -> URL? {
        guard policy != .keepAll, isVideo(url) else { return nil }
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let metadata: [AVMetadataItem]
        do {
            metadata = try await allMetadata(of: asset)
        } catch {
            throw ImageMetadataError.couldNotRewrite(name)
        }
        let hasLocation = await containsLocation(metadata)
        guard hasLocation || (policy == .removeAll && !metadata.isEmpty) else { return nil }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ImageMetadataError.couldNotRewrite(name)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AktarMetadata", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(name)
        session.outputURL = output
        session.outputFileType = fileType(for: url)
        // The asset's own items, less what goes; the filter also drops
        // location and personal items from the tracks.
        let assetMetadata = (try? await asset.load(.metadata)) ?? []
        var kept: [AVMetadataItem] = []
        if policy != .removeAll {
            for item in assetMetadata where !(await isLocation(item)) { kept.append(item) }
        }
        // An empty list makes the export keep the source's own metadata,
        // so when nothing is kept a single neutral marker stands in for it.
        session.metadata = kept.isEmpty ? [cleanedMarker()] : kept
        session.metadataItemFilter = .forSharing()

        nonisolated(unsafe) let exporter = session
        await withTaskCancellationHandler {
            await exporter.export()
        } onCancel: {
            exporter.cancelExport()
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: directory)
            throw CancellationError()
        }

        let written = session.status == .completed ? try? await allMetadata(of: AVURLAsset(url: output)) : nil
        let stillHasLocation = await containsLocation(written ?? [])
        guard let written, !stillHasLocation,
              policy != .removeAll || !written.contains(where: isIdentifying) else {
            try? FileManager.default.removeItem(at: directory)
            throw ImageMetadataError.couldNotRewrite(name)
        }
        return output
    }

    /// "com.getaktar.cleaned" = "1": says nothing about the video or who
    /// made it.
    private static func cleanedMarker() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.getaktar.cleaned" as NSString
        item.value = "1" as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        default: return .mp4
        }
    }

    /// The asset's metadata and its tracks'.
    private static func allMetadata(of asset: AVURLAsset) async throws -> [AVMetadataItem] {
        var items = try await asset.load(.metadata)
        for track in try await asset.load(.tracks) {
            items += try await track.load(.metadata)
        }
        return items
    }

    private static func containsLocation(_ items: [AVMetadataItem]) async -> Bool {
        for item in items where await isLocation(item) { return true }
        return false
    }

    /// Where it was recorded, in any of the forms QuickTime, MPEG-4 and
    /// ID3 keep it. Tools write it under keys AVFoundation doesn't always
    /// name (an iTunes-style list with numbered keys), so a value that
    /// reads like ISO 6709 coordinates counts too.
    private static func isLocation(_ item: AVMetadataItem) async -> Bool {
        let identifiers: Set<AVMetadataIdentifier> = [
            .commonIdentifierLocation,
            .quickTimeMetadataLocationISO6709,
            .quickTimeMetadataLocationName,
            .quickTimeMetadataLocationBody,
            .quickTimeMetadataLocationNote,
            .quickTimeMetadataLocationRole,
            .quickTimeMetadataLocationDate,
            .quickTimeUserDataLocationISO6709,
            .quickTimeMetadataLocationHorizontalAccuracyInMeters,
        ]
        if let identifier = item.identifier {
            if identifiers.contains(identifier) { return true }
            let raw = identifier.rawValue.lowercased()
            if raw.contains("location") || raw.contains("%a9xyz") || raw.contains("\u{a9}xyz") { return true }
        }
        if item.commonKey == .commonKeyLocation { return true }
        guard let value = try? await item.load(.stringValue) else { return false }
        return looksLikeISO6709(value)
    }

    /// "+41.0082+028.9784+000.000/" and the like: a signed latitude
    /// followed by a signed longitude.
    static func looksLikeISO6709(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces)
            .range(of: #"^[+-]\d{2,6}(\.\d+)?[+-]\d{3,7}(\.\d+)?"#, options: .regularExpression) != nil
    }

    /// What tells who made it and with what, checked after "Remove all".
    private static func isIdentifying(_ item: AVMetadataItem) -> Bool {
        let keys: Set<AVMetadataKey> = [.commonKeyMake, .commonKeyModel, .commonKeySoftware, .commonKeyAuthor, .commonKeyCreator]
        return item.commonKey.map(keys.contains) ?? false
    }
}
