import Foundation

/// Out-of-band lightweight appcast probe. Used by `UpdaterController`
/// when Sparkle's session is in progress (held reply for a pending
/// offer) — in that state Sparkle's own `checkForUpdatesInBackground`
/// silently no-ops, so a newer release published after the first
/// offer wouldn't surface mid-session. We bypass Sparkle entirely:
/// fetch the appcast URL directly with the same `_t` cache-bust
/// scheme `UpdaterDelegate.feedParameters` uses, regex out every
/// `<sparkle:version>` integer, return the max.
///
/// We only need the build number for comparison against the current
/// pending offer; no need to fully parse the feed.
enum AppcastProbe {
    static func probeLatestBuildNumber(feedURL: URL) async throws -> Int? {
        var url = feedURL
        if var comps = URLComponents(url: feedURL, resolvingAgainstBaseURL: false) {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970))))
            comps.queryItems = items
            if let resolved = comps.url { url = resolved }
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        let regex = try NSRegularExpression(pattern: #"<sparkle:version>(\d+)</sparkle:version>"#)
        let range = NSRange(xml.startIndex..., in: xml)
        var maxBuild: Int = 0
        regex.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let m = match,
                  let r = Range(m.range(at: 1), in: xml),
                  let n = Int(xml[r])
            else { return }
            if n > maxBuild { maxBuild = n }
        }
        return maxBuild > 0 ? maxBuild : nil
    }
}
