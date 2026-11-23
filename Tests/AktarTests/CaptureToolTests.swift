import AppKit
import XCTest

/// Capture tools (docs/capture-tools.md): the tools and their start URLs,
/// spotting a tool's new image in its save folder or on the clipboard,
/// and files a capture took that a watched folder then skips.
@MainActor
final class CaptureToolTests: XCTestCase {
    // MARK: - Tools

    func testSystemToolIsTheDefaultAndAlwaysInstalled() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: CaptureTool.settingKey)
        defer { defaults.set(saved, forKey: CaptureTool.settingKey) }

        defaults.removeObject(forKey: CaptureTool.settingKey)
        XCTAssertEqual(CaptureTool.current, .system)
        defaults.set("no-such-tool", forKey: CaptureTool.settingKey)
        XCTAssertEqual(CaptureTool.current, .system)
        XCTAssertTrue(CaptureTool.system.isInstalled)
        XCTAssertEqual(CaptureTool.ordered.first, .system)
        XCTAssertEqual(Set(CaptureTool.ordered), Set(CaptureTool.allCases))
    }

    func testToolsStartStraightIntoTheirEditor() {
        XCTAssertEqual(CaptureTool.cleanShot.kind, .urlScheme(URL(string: "cleanshot://capture-area?action=annotate")!))
        XCTAssertEqual(CaptureTool.shottr.kind, .urlScheme(URL(string: "shottr://grab/area?then=edit")!))
        XCTAssertEqual(CaptureTool.macshot.kind, .urlScheme(URL(string: "macshot://capture")!))
        XCTAssertEqual(CaptureTool.flameshot.kind, .process)
        XCTAssertEqual(CaptureTool.system.kind, .systemTool)
    }

    func testOnlyURLSchemeToolsHaveASaveFolder() {
        XCTAssertTrue(CaptureTool.cleanShot.usesSaveFolder)
        XCTAssertTrue(CaptureTool.shottr.usesSaveFolder)
        XCTAssertTrue(CaptureTool.macshot.usesSaveFolder)
        XCTAssertFalse(CaptureTool.flameshot.usesSaveFolder)
        XCTAssertFalse(CaptureTool.system.usesSaveFolder)
    }

    func testEveryOtherToolHasSetupStepsAndAWebsite() {
        for tool in CaptureTool.allCases where tool != .system {
            XCTAssertFalse(tool.setupSteps.isEmpty, tool.rawValue)
            XCTAssertNotNil(tool.website, tool.rawValue)
        }
    }

    func testCapturedFilesAreNamedLikeMacOSScreenshots() {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 11, 23)
        (components.hour, components.minute, components.second) = (14, 3, 12)
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(CaptureImageFiles.filename(for: date), "Screenshot 2026-11-23 at 14.03.12.png")
        XCTAssertEqual(CaptureImageFiles.filename(for: date, fileExtension: "jpg"), "Screenshot 2026-11-23 at 14.03.12.jpg")
    }

    // MARK: - Save folder

    func testOnlyImagesAreTaken() {
        XCTAssertTrue(CaptureImageFiles.isImage("CleanShot 2026-11-23 at 14.03.12@2x.png"))
        XCTAssertTrue(CaptureImageFiles.isImage("a.JPEG"))
        XCTAssertFalse(CaptureImageFiles.isImage(".CleanShot.png"))
        XCTAssertFalse(CaptureImageFiles.isImage("recording.mp4"))
        XCTAssertFalse(CaptureImageFiles.isImage("notes"))
    }

    func testANewImageIsTakenOnceItsSizeSettles() {
        let start = Date(timeIntervalSince1970: 1000)
        var detector = NewImageDetector(baseline: ["old.png": 10])
        XCTAssertNil(detector.observe(["old.png": 10], at: start))
        XCTAssertNil(detector.observe(["old.png": 10, "new.png": 0], at: start.addingTimeInterval(0.25)))
        XCTAssertNil(detector.observe(["old.png": 10, "new.png": 500], at: start.addingTimeInterval(0.5)))
        XCTAssertNil(detector.observe(["old.png": 10, "new.png": 900], at: start.addingTimeInterval(0.75)))
        XCTAssertNil(detector.observe(["old.png": 10, "new.png": 900], at: start.addingTimeInterval(1.0)))
        XCTAssertEqual(detector.observe(["old.png": 10, "new.png": 900], at: start.addingTimeInterval(1.3)), "new.png")
    }

    func testAnEmptyFileIsNeverTaken() {
        let start = Date(timeIntervalSince1970: 1000)
        var detector = NewImageDetector(baseline: [:])
        XCTAssertNil(detector.observe(["new.png": 0], at: start))
        XCTAssertNil(detector.observe(["new.png": 0], at: start.addingTimeInterval(5)))
    }

    func testChangesToFilesThatWereThereAreIgnored() {
        let start = Date(timeIntervalSince1970: 1000)
        var detector = NewImageDetector(baseline: ["old.png": 10])
        XCTAssertNil(detector.observe(["old.png": 99], at: start))
        XCTAssertNil(detector.observe(["old.png": 99], at: start.addingTimeInterval(5)))
    }

    func testAFileRemovedWhileWrittenMovesOnToTheNextOne() {
        let start = Date(timeIntervalSince1970: 1000)
        var detector = NewImageDetector(baseline: [:])
        XCTAssertNil(detector.observe(["a.png": 5], at: start))
        XCTAssertNil(detector.observe(["b.png": 7], at: start.addingTimeInterval(0.25)))
        XCTAssertEqual(detector.candidate?.name, "b.png")
        XCTAssertEqual(detector.observe(["b.png": 7], at: start.addingTimeInterval(0.8)), "b.png")
    }

    func testFolderListingFindsImagesOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 3).write(to: folder.appendingPathComponent("shot.png"))
        try Data(count: 4).write(to: folder.appendingPathComponent("notes.txt"))
        try Data(count: 5).write(to: folder.appendingPathComponent(".hidden.png"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
        XCTAssertEqual(CaptureImageFiles.list(folder), ["shot.png": 3])
    }

    // MARK: - Clipboard

    func testPNGOnTheClipboardIsTakenAsItIs() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("aktar-capture-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let png = Self.pngData()
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        guard case .data(let data, let fileExtension) = PasteboardImage.read(from: pasteboard) else {
            return XCTFail("no image")
        }
        XCTAssertEqual(data, png)
        XCTAssertEqual(fileExtension, "png")
    }

    func testTIFFOnTheClipboardBecomesPNG() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("aktar-capture-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Self.pngData()))
        pasteboard.clearContents()
        pasteboard.setData(try XCTUnwrap(rep.tiffRepresentation), forType: .tiff)
        guard case .data(let data, "png") = PasteboardImage.read(from: pasteboard) else {
            return XCTFail("no PNG")
        }
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testTextOnTheClipboardIsNotAnImage() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("aktar-capture-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertNil(PasteboardImage.read(from: pasteboard))
    }

    // MARK: - Watched folders

    func testClaimedFilesAreRecognisedByPath() {
        let url = URL(fileURLWithPath: "/tmp/aktar-claims-\(UUID().uuidString)/shot.png")
        XCTAssertFalse(CaptureClaims.isClaimed(url))
        CaptureClaims.claim(url)
        XCTAssertTrue(CaptureClaims.isClaimed(url))
        XCTAssertTrue(CaptureClaims.isClaimed(URL(fileURLWithPath: url.deletingLastPathComponent().path + "/./shot.png")))
    }

    // MARK: - Waiting

    func testANewWaitEndsTheOldOne() {
        let waiting = CaptureWaiting()
        let first = waiting.begin(.cleanShot)
        XCTAssertEqual(waiting.tool, .cleanShot)
        waiting.stop()
        XCTAssertFalse(waiting.isCurrent(first))
        XCTAssertNil(waiting.tool)
        let second = waiting.begin(.shottr)
        waiting.end(first)
        XCTAssertEqual(waiting.tool, .shottr, "an old wait ending leaves the new one alone")
        waiting.end(second)
        XCTAssertNil(waiting.tool)
    }

    private static func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
}
