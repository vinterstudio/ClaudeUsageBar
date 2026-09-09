import Foundation

/// One rate-limit window reported by the usage endpoint.
struct UsageWindow {
    let label: String          // e.g. "5h", "7d"
    let percent: Int           // 0...100 utilization
    let resetsAt: Date?
    /// True when `resetsAt` was derived rather than reported. The plan-usage
    /// file carries no reset timestamps, so its reset time is inferred from the
    /// sample series and must never be presented as exact.
    var resetIsEstimated: Bool = false
}

struct UsageSnapshot {
    let windows: [UsageWindow]
    /// The window most useful for the menu bar: the 5-hour session if present, else the busiest.
    var primary: UsageWindow? {
        windows.first(where: { $0.label.contains("5") }) ??
        windows.max(by: { $0.percent < $1.percent })
    }
}

enum UsageError: Error { case http(Int, String), parse(String) }

/// Fetches the OAuth usage endpoint. This is a metadata call: it consumes
/// no model/inference tokens, only a tiny HTTPS round-trip.
final class UsageClient {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Where the most recent raw response is written, for inspection/debugging.
    static let rawLogPath: String = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/ClaudeUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-usage-response.json").path
    }()

    func fetch(accessToken: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: Self.url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.http(-1, "no response") }
        // Persist the raw body so the exact shape can always be inspected,
        // even before the parser is confirmed against a live response.
        try? data.write(to: URL(fileURLWithPath: Self.rawLogPath))

        guard http.statusCode == 200 else {
            throw UsageError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.parse("not a JSON object")
        }
        return Self.parse(obj)
    }

    /// Defensive parser: walks the top-level keys looking for objects that carry a
    /// utilization/percentage value plus an optional reset timestamp. Tolerates the
    /// endpoint's field-name variations across Claude Code versions.
    static func parse(_ obj: [String: Any]) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        for (key, value) in obj {
            guard let dict = value as? [String: Any] else { continue }
            guard let pct = number(in: dict, keys: ["utilization", "percent", "percentage", "used_percent"]) else { continue }
            let reset = date(in: dict, keys: ["resets_at", "reset_at", "resetsAt", "reset"])
            windows.append(UsageWindow(label: shortLabel(key), percent: clampPercent(pct), resetsAt: reset))
        }
        // Stable, predictable ordering: 5h first, then 7d, then the rest.
        windows.sort { lhs, rhs in
            func rank(_ l: String) -> Int { l.contains("5") ? 0 : (l.contains("7") ? 1 : 2) }
            return rank(lhs.label) < rank(rhs.label)
        }
        return UsageSnapshot(windows: windows)
    }

    private static func clampPercent(_ d: Double) -> Int {
        // Accept either a 0..1 fraction or a 0..100 percentage. Only a value
        // strictly below 1 is unambiguously a fraction: `1` means 1% far more
        // often than it means "the whole quota", and scaling it to 100 turned
        // the least-used state into the most alarming reading.
        let v = d < 1.0 ? d * 100 : d
        return max(0, min(100, Int(v.rounded())))
    }

    private static func number(in dict: [String: Any], keys: [String]) -> Double? {
        for k in keys {
            if let n = dict[k] as? Double { return n }
            if let n = dict[k] as? Int { return Double(n) }
            if let s = dict[k] as? String, let n = Double(s) { return n }
        }
        return nil
    }

    private static func date(in dict: [String: Any], keys: [String]) -> Date? {
        // The endpoint sends fractional seconds (e.g. "...:00.810533+00:00"),
        // which the default ISO8601 parser rejects — try with and without them.
        let fracFmt = ISO8601DateFormatter()
        fracFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFmt = ISO8601DateFormatter()
        for k in keys {
            if let s = dict[k] as? String,
               let d = fracFmt.date(from: s) ?? plainFmt.date(from: s) { return d }
            if let n = dict[k] as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
            if let n = dict[k] as? Int { let nn = Double(n); return Date(timeIntervalSince1970: nn > 1e12 ? nn / 1000 : nn) }
        }
        return nil
    }

    private static func shortLabel(_ key: String) -> String {
        let k = key.lowercased()
        if k.contains("five") || k.contains("5") { return "5h" }
        if k.contains("seven") || k.contains("7") { return k.contains("opus") ? "7d-opus" : "7d" }
        return key
    }
}
