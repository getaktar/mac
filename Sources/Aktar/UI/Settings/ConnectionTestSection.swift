import SwiftUI

/// What Test Connection found, as a Form section: why it couldn't reach the
/// bucket at all, or one line per step of the test, so a bucket that takes
/// uploads but won't serve them reads as a problem instead of a success.
/// Shows nothing before a test has run.
struct ConnectionTestSection: View {
    var result: ConnectionResult?
    /// Why the test couldn't reach the bucket at all.
    var error: String?

    var body: some View {
        if let error {
            Section {
                Label(error, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } else if let result {
            Section {
                if result.writable {
                    Label("Upload: works", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Upload: failed. This key can read the bucket but can\u{2019}t write to it.", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                switch result.publicLink {
                case .reachable:
                    Label("Public link: works", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .status(let code):
                    Label("Public link: failed (HTTP \(String(code)))", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .noResponse:
                    Label("Public link: no response", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            } footer: {
                if let hint = Self.publicLinkHint(result.publicLink) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func publicLinkHint(_ check: PublicLinkCheck?) -> String? {
        switch check {
        case .status(401), .status(403):
            return String(localized: "Uploads work, but anyone who opens a link gets an error. Allow public reads on the bucket (on R2, turn on the r2.dev URL or connect a custom domain), or keep it private and share files with Copy Temporary Link in the Library.")
        case .status(404):
            return String(localized: "The test file was uploaded, but it isn\u{2019}t at the Public Base URL. Check that the URL points to this bucket.")
        case .status, .noResponse:
            return String(localized: "The Public Base URL didn\u{2019}t serve the test file. Check the domain and that it points to this bucket.")
        case .reachable, nil:
            return nil
        }
    }
}
