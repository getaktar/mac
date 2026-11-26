import AppKit
import SwiftUI

/// "Copy Temporary Link" for an upload in history: a fresh presigned link,
/// which works even when the bucket is private or the one copied at upload
/// time has run out. It also shows one as a QR code.
struct RecordTemporaryLinkMenu: View {
    let record: UploadRecord
    @Environment(AppState.self) private var appState

    var body: some View {
        // An encrypted upload's file can't be opened on its own.
        if !record.isEncrypted, canSign { menu }
    }

    /// Only where the upload's destination signs links (one that's gone
    /// keeps the menu, which then says so).
    private var canSign: Bool {
        appState.destinationStore.destinations.first { $0.id == record.destinationID }?.capabilities.temporaryLinks ?? true
    }

    private var menu: some View {
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
            Divider()
            Menu("Show QR Code") {
                ForEach(TemporaryLinkDuration.allCases) { duration in
                    Button(duration.title) {
                        QRCodeWindowController.shared.show(for: record, validFor: duration, uploadManager: appState.uploadManager)
                    }
                }
            }
        }
    }
}
