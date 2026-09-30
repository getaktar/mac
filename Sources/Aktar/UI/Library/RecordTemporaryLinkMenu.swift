import AppKit
import SwiftUI

/// "Copy Temporary Link" for an upload in history: a fresh presigned link,
/// which works even when the bucket is private or the one copied at upload
/// time has run out.
struct RecordTemporaryLinkMenu: View {
    let record: UploadRecord
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu("Copy Temporary Link") {
            ForEach(TemporaryLinkDuration.allCases) { duration in
                Button(duration.title) {
                    Task {
                        do {
                            let url = try await appState.uploadManager.temporaryURL(for: record, validFor: duration)
                            ClipboardService.copy(url.absoluteString)
                        } catch {
                            NSSound.beep()
                        }
                    }
                }
            }
        }
    }
}
