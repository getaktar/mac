import AppKit
import Security

/// Who gets the local API token when Raycast pairs: the app that opens
/// raycast:// links, but only when that's Raycast itself (its bundle ID and
/// a valid Developer ID signature from Raycast's team), so another app that
/// claims the scheme, or a Mac without Raycast, never receives it.
enum RaycastApp {
    static let bundleID = "com.raycast.macos"
    /// Raycast Technologies Inc's Developer ID team.
    static let teamID = "SY64MV22J9"

    /// The app that opens `target`, when it's Raycast; nil otherwise.
    static func handler(opening target: URL) -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: target), isRaycast(app) else { return nil }
        return app
    }

    static func isRaycast(_ app: URL) -> Bool {
        guard Bundle(url: app)?.bundleIdentifier == bundleID else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}
