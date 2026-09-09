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
        let series = samples()
        guard let latest = series.last else { return nil }
        let reset = sessionReset(in: series)
        return UsageSnapshot(windows: [
            UsageWindow(label: "5h", percent: latest.fiveHour,
                        resetsAt: reset, resetIsEstimated: reset != nil),
            UsageWindow(label: "7d", percent: latest.sevenDay, resetsAt: nil),
        ])
    }

    /// Estimated end of the current five-hour window.
    ///
    /// The file records no reset timestamps, so this is derived. The window runs
    /// five hours from your first message, which shows up in the series as the
    /// most recent transition from `fh == 0` to `fh > 0`; five hours after that
    /// point is the reset. Measured against 41 windows in a real 30-day series,
    /// the interval from that transition to the next drop clusters tightly at
    /// 4.9–5.1h. The outliers are all sampling gaps (the Mac asleep), not a
    /// different window length.
    ///
    /// Accurate to about the sampling interval — roughly ±8 minutes — which is
    /// why every caller renders it with a "≈".
    ///
    /// Returns nil when there is no active window (`fh` is 0), when no
    /// transition is visible in the retained series, or when the derived reset
    /// is already in the past — that last case means a boundary was missed
    /// while the machine was asleep, and a stale time is worse than none.
    static func sessionReset(in series: [Sample]? = nil) -> Date? {
        let s = series ?? samples()
        guard let latest = s.last, latest.fiveHour > 0, s.count > 1 else { return nil }

        var start: Date?
        for i in stride(from: s.count - 1, to: 0, by: -1) where s[i - 1].fiveHour == 0 && s[i].fiveHour > 0 {
            // The first message landed somewhere between the two samples.
            start = Date(timeIntervalSince1970:
                (s[i - 1].date.timeIntervalSince1970 + s[i].date.timeIntervalSince1970) / 2)
            break
        }
        guard let start else { return nil }

        let reset = start.addingTimeInterval(5 * 3600)
        return reset > Date() ? reset : nil
    }

    /// Half the sampling interval, as the ± on the estimate above.
    static func samplingUncertainty(in series: [Sample]? = nil) -> TimeInterval {
        let s = series ?? samples()
        guard s.count > 2 else { return 450 }
        var gaps: [TimeInterval] = []
        for i in 1..<s.count { gaps.append(s[i].date.timeIntervalSince(s[i - 1].date)) }
        gaps.sort()
        return gaps[gaps.count / 2] / 2
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
