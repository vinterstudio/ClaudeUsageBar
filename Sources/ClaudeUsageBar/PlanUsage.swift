import Foundation

/// Reads the quota percentages the Claude desktop app already records locally.
///
/// `~/Library/Application Support/Claude/plan-usage-history.json` holds a rolling
/// 30-day series sampled roughly every 15 minutes:
///
///     { "version": 2,
///       "samples": [ { "t": <epoch ms>, "org": "<uuid>", "u": { "fh": 31, "sd": 50 } } ] }
///
/// `fh` is five-hour utilization, `sd` seven-day, both already 0–100.
///
/// This replaced the OAuth endpoint as the primary source on 2026-09-09. The
/// keychain item `Claude Code-credentials` that fed that endpoint now contains
/// empty token strings — Claude Code moved its credentials into the Electron
/// "Claude Safe Storage" key — so on a desktop-app machine the network path can
/// no longer authenticate at all. Reading this file needs no credentials, makes
/// no network call, and cannot raise a keychain prompt.
///
/// The trade-off is that the file carries no reset timestamps, so a snapshot
/// from this source has none and the UI omits them rather than inventing one.
enum PlanUsageFile {
    static let path: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        .path

    struct Sample {
        let date: Date
        let fiveHour: Int
        let sevenDay: Int
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// When the file was last written — how fresh the numbers are.
    static var lastModified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The whole series, oldest first. Empty if the file is missing or unreadable.
    static func samples() -> [Sample] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["samples"] as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry in
            guard let t = entry["t"] as? Double, let u = entry["u"] as? [String: Any] else { return nil }
            return Sample(date: Date(timeIntervalSince1970: t / 1000),
                          fiveHour: clamp(u["fh"]),
                          sevenDay: clamp(u["sd"]))
        }.sorted { $0.date < $1.date }
    }

    /// Current quota as a snapshot, or nil if the file has nothing usable.
    static func snapshot() -> UsageSnapshot? {
        guard let latest = samples().last else { return nil }
        return UsageSnapshot(windows: [
            UsageWindow(label: "5h", percent: latest.fiveHour, resetsAt: nil),
            UsageWindow(label: "7d", percent: latest.sevenDay, resetsAt: nil),
        ])
    }

    private static func clamp(_ any: Any?) -> Int {
        let value: Double
        switch any {
        case let n as Double: value = n
        case let n as Int: value = Double(n)
        default: return 0
        }
        return max(0, min(100, Int(value.rounded())))
    }
}
