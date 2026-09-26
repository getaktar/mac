import UniformTypeIdentifiers

/// A generic SF Symbol for a file, based on its extension, used wherever a
/// real thumbnail isn't available (non-image files, or an image that hasn't
/// been cached yet).
enum FileKindIcon {
    static func symbolName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return "doc.fill"
        }
        if type.conforms(to: .image) { return "photo.fill" }
        if type.conforms(to: .pdf) { return "doc.richtext.fill" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .movie) { return "film.fill" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .text) { return "doc.text.fill" }
        return "doc.fill"
    }
}
