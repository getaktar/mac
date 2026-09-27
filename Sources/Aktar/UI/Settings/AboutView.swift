import AppKit
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    static let developerName = "Mert Topuz"
    static let developerWebsite = URL(string: "https://merttopuz.com")!
    static let developerGitHub = URL(string: "https://github.com/merttopuz")!
    static let repository = URL(string: "https://github.com/getaktar/mac")!
    static let changelog = URL(string: "https://github.com/getaktar/mac/blob/main/CHANGELOG.md")!
    static let issues = URL(string: "https://github.com/getaktar/mac/issues")!
    static let sponsor = URL(string: "https://buymeacoffee.com/merttopuz")!

    /// getaktar.com in the language the app is running in, so the site opens
    /// on the matching locale (the site uses lowercase path prefixes).
    static var website: URL {
        let sitePrefixes = [
            "tr": "tr", "de": "de", "fr": "fr", "es": "es",
            "pt-BR": "pt-br", "ja": "ja", "zh-Hans": "zh",
        ]
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let prefix = sitePrefixes[language] else { return URL(string: "https://getaktar.com/")! }
        return URL(string: "https://getaktar.com/\(prefix)/")!
    }
}

/// The standard macOS About panel, with credits linking to the website and
/// the developer. Shown from the app menu while a window is open.
enum AboutPanel {
    @MainActor
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString()
        func append(_ text: String, link: URL? = nil) {
            var attributes = baseAttributes
            if let link { attributes[.link] = link }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }

        append(String(localized: "Your files. Your storage. One shortcut away.") + "\n")
        append(AppInfo.website.host() ?? "getaktar.com", link: AppInfo.website)
        append("\n")
        append(String(localized: "Developed by \(AppInfo.developerName)"), link: AppInfo.developerWebsite)

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(title: "About", subtitle: "Version details, links, and who makes Aktar.") {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Aktar").font(.title3.bold())
                    Text("Your files. Your storage. One shortcut away.")
                        .foregroundStyle(.secondary)
                    Text("Version \(AppInfo.version) (\(AppInfo.build))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            SettingsSection(title: "Aktar") {
                SettingsCard {
                    AboutLinkRow(title: "Website", detail: AppInfo.website.host(), systemImage: "globe", url: AppInfo.website)
                    SettingsCardDivider()
                    AboutLinkRow(title: "Source Code", systemImage: "chevron.left.forwardslash.chevron.right", url: AppInfo.repository)
                    SettingsCardDivider()
                    AboutLinkRow(title: "What\u{2019}s New", systemImage: "sparkles", url: AppInfo.changelog)
                    SettingsCardDivider()
                    AboutLinkRow(title: "Report an Issue", systemImage: "ladybug", url: AppInfo.issues)
                }
            }

            SettingsSection(title: "Developer") {
                SettingsCard {
                    AboutLinkRow(
                        verbatimTitle: AppInfo.developerName,
                        detail: AppInfo.developerWebsite.host(),
                        systemImage: "person.crop.circle",
                        url: AppInfo.developerWebsite
                    )
                    SettingsCardDivider()
                    AboutLinkRow(title: "GitHub", detail: "@merttopuz", systemImage: "at", url: AppInfo.developerGitHub)
                    SettingsCardDivider()
                    AboutLinkRow(title: "Buy Me a Coffee", systemImage: "cup.and.saucer", url: AppInfo.sponsor)
                }
            }

            Text("Free and open source under the MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AboutLinkRow: View {
    let title: Text
    let detail: String?
    let systemImage: String
    let url: URL

    init(title: LocalizedStringKey, detail: String? = nil, systemImage: String, url: URL) {
        self.title = Text(title)
        self.detail = detail
        self.systemImage = systemImage
        self.url = url
    }

    init(verbatimTitle: String, detail: String? = nil, systemImage: String, url: URL) {
        self.title = Text(verbatim: verbatimTitle)
        self.detail = detail
        self.systemImage = systemImage
        self.url = url
    }

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                title
                Spacer()
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(12)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}
