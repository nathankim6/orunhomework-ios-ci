import Foundation
import WebKit

/// Everything about the single site this shell is allowed to display.
///
/// The app never bundles a web build: every launch opens the deployed site, so a web
/// deployment reaches App Store users immediately, with no new binary and no re-review.
enum Site {
    /// Canonical production origin. The web app itself uses this host for student
    /// access links and for report links (`/r/<token>`), so cookies, localStorage and
    /// Supabase calls behave here exactly as they do in Safari.
    static let host = "orunhomework.com"
    static let rootURL = URL(string: "https://orunhomework.com/")!

    /// `www` answers with a 301 to the apex host; keeping it trusted lets that redirect
    /// finish inside the web view instead of bouncing the user out to Safari.
    private static let trustedHosts: Set<String> = ["orunhomework.com", "www.orunhomework.com"]

    static func isTrusted(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              trustedHosts.contains(host),
              url.user == nil,
              url.password == nil
        else { return false }
        if let port = url.port, port != 443 { return false }
        return true
    }

    /// Same check for the origin a page frame reports, used before trusting a message
    /// or a capture request that came from inside the web view.
    static func isTrustedOrigin(_ origin: WKSecurityOrigin) -> Bool {
        guard origin.protocol == "https", trustedHosts.contains(origin.host.lowercased()) else { return false }
        return origin.port == 0 || origin.port == 443
    }

    static func isWebURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// Fingerprint of a deployed build: the content-hashed asset names Vite emits
    /// (`/assets/index-B2OoadEh.js`). A new web deployment changes them, which is all
    /// the app needs in order to know that reloading will show newer UI.
    ///
    /// Returns nil when the page carries no recognisable asset references, so an
    /// unexpected response can never be mistaken for a new build.
    static func assetSignature(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "/assets/[A-Za-z0-9_@.\\-]+\\.(?:js|css)") else { return nil }
        let ns = html as NSString
        let found = Set(regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
        guard !found.isEmpty else { return nil }
        return found.sorted().joined(separator: " ")
    }
}
