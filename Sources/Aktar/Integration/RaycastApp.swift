import AppKit
import Security

/// Who gets the local API token when an app pairs: the app that opens the
/// callback's links, but only when that's the app itself (its bundle ID and
/// a valid Developer ID signature from its team), so another app that
/// claims the scheme, or a Mac without the app, never receives it.
enum SignedApp {
    /// The app that opens `target`, when it's the one with `bundleID`
    /// signed by `teamID`; nil otherwise.
    static func handler(opening target: URL, bundleID: String, teamID: String) -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: target),
              isGenuine(app, bundleID: bundleID, teamID: teamID) else { return nil }
        return app
    }

    static func isGenuine(_ app: URL, bundleID: String, teamID: String) -> Bool {
        guard Bundle(url: app)?.bundleIdentifier == bundleID else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}

/// Raycast, for the Aktar extension's pairing.
enum RaycastApp {
    static let bundleID = "com.raycast.macos"
    /// Raycast Technologies Inc's Developer ID team.
    static let teamID = "SY64MV22J9"

    static func handler(opening target: URL) -> URL? {
        SignedApp.handler(opening: target, bundleID: bundleID, teamID: teamID)
    }

    static func isRaycast(_ app: URL) -> Bool {
        SignedApp.isGenuine(app, bundleID: bundleID, teamID: teamID)
    }
}

/// Obsidian, for the Aktar plugin's pairing.
enum ObsidianApp {
    static let bundleID = "md.obsidian"
    /// Dynalist Inc's Developer ID team, which signs Obsidian.
    static let teamID = "6JSW4SJWN9"

    static func handler(opening target: URL) -> URL? {
        SignedApp.handler(opening: target, bundleID: bundleID, teamID: teamID)
    }

    static func isObsidian(_ app: URL) -> Bool {
        SignedApp.isGenuine(app, bundleID: bundleID, teamID: teamID)
    }
}
