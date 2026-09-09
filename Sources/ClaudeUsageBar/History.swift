import Foundation

/// Token totals for one bucket (a day, or a project).
struct TokenTotals {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    /// Fresh tokens: what this turn actually cost to move through the model.
    ///
    /// Cache reads are deliberately EXCLUDED. On a real corpus they dominate the
    /// raw count — around 98% of it, measured over a 30-day window — so including
    /// them makes every chart a picture of cache-read volume and buries the
    /// day-to-day signal. They are an order of magnitude cheaper than a fresh read, and are
    /// reported separately as `cacheRead`.
    var total: Int { input + output + cacheWrite }

    /// Every token the API touched, cache reads included — the number to quote
    /// when comparing against a raw provider total.
    var totalIncludingCacheReads: Int { total + cacheRead }

    static func + (l: TokenTotals, r: TokenTotals) -> TokenTotals {
        TokenTotals(input: l.input + r.input,
                    output: l.output + r.output,
                    cacheRead: l.cacheRead + r.cacheRead,
                    cacheWrite: l.cacheWrite + r.cacheWrite)
    }
}

/// A rolling window of token usage reconstructed from Claude Code's own
/// transcript logs.
struct HistorySnapshot {
    /// Oldest → newest, one entry per calendar day in the window (gaps filled
    /// with zeros so a chart has an even x-axis).
    var days: [(day: Date, totals: TokenTotals)] = []
    /// Project directory name → totals over the whole window, busiest first.
    var projects: [(name: String, totals: TokenTotals)] = []
    var windowDays: Int = 30
    var generatedAt = Date()

    var grandTotal: TokenTotals { days.reduce(TokenTotals()) { $0 + $1.totals } }
    var busiestDay: Int { days.map(\.totals.total).max() ?? 0 }

    /// Invented data for published screenshots, so a README image is never a
    /// picture of the author's real projects and volumes. Shaped like a real
    /// corpus — a weekday rhythm, one outlier day, a long cache-read tail — so
    /// it still exercises the chart's scaling.
    static func demo(windowDays: Int = 30) -> HistorySnapshot {
        var snapshot = HistorySnapshot()
        snapshot.windowDays = windowDays
        let today = Calendar.current.startOfDay(for: Date())
        let shape: [Double] = [
            0.55, 0.72, 0.61, 0.80, 0.44, 0.06, 0.10,
            0.68, 0.91, 0.75, 0.58, 0.83, 0.12, 0.04,
            0.70, 0.66, 0.88, 0.52, 0.79, 0.09, 0.15,
            0.62, 0.85, 1.00, 0.71, 0.60, 0.08, 0.05,
            0.74, 0.48,
        ]
        snapshot.days = (0..<windowDays).map { offset in
            let day = Calendar.current.date(byAdding: .day, value: offset - (windowDays - 1),
                                            to: today) ?? today
            let f = shape[offset % shape.count]
            let fresh = Int(f * 2_400_000)
            return (day: day,
                    totals: TokenTotals(input: fresh / 5,
                                        output: fresh / 8,
                                        cacheRead: fresh * 70,
                                        cacheWrite: fresh - fresh / 5 - fresh / 8))
        }
        snapshot.projects = [
            ("api-gateway", 18_400_000), ("dotfiles", 9_100_000),
            ("web-client", 6_700_000), ("scratch", 2_050_000),
        ].map { (name: $0.0, totals: TokenTotals(input: $0.1 / 3, output: $0.1 / 6,
                                                 cacheRead: $0.1 * 70,
                                                 cacheWrite: $0.1 - $0.1 / 3 - $0.1 / 6)) }
        return snapshot
    }
}

/// Scans `~/.claude/projects/**/*.jsonl` for per-assistant-turn token counts.
///
/// Two things make this cheap enough to run on a timer against a corpus that is
/// already the better part of a gigabyte:
///
/// 1. **Incremental reads.** Each file's parsed byte offset is remembered, so a
///    refresh only decodes bytes appended since the last pass. A full scan
///    happens once, at first launch.
/// 2. **Line prefiltering.** Only lines that actually contain a usage object are
///    handed to `JSONSerialization`; the rest (user turns, tool results, large
///    pasted files) are skipped without being decoded.
///
/// This reads only local files that Claude Code has already written. It makes no
/// network calls and needs no API key.
final class HistoryStore {
    struct FileCursor {
        var offset: UInt64
        var modified: Date
    }

    /// One assistant turn's contribution, kept so the rolling window can drop
    /// entries that age out without re-reading the logs.
    private struct Entry {
        let day: Date
        let project: String
        let totals: TokenTotals
    }

    private let root: URL
    private let windowDays: Int
    private var cursors: [String: FileCursor] = [:]
    /// Dedupe: Claude Code can write the same assistant turn more than once
    /// (retries, resumed sessions), and `requestId` is stable across those.
    private var seenRequests = Set<String>()
    private var entries: [Entry] = []

    init(root: URL? = nil, windowDays: Int = 30) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        self.windowDays = windowDays
    }

    /// Rescans anything that changed and returns the current window.
    /// Safe to call from a background queue; must not be called concurrently
    /// with itself (the caller serialises it on one queue).
    func refresh() -> HistorySnapshot {
        let cutoff = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(-Double(windowDays - 1) * 86_400))

        for url in transcriptURLs(modifiedAfter: cutoff) {
            scan(url)
        }

        // Drop anything that has aged out of the rolling window.
        entries.removeAll { $0.day < cutoff }
        return assemble(cutoff: cutoff)
    }

    // MARK: - Scanning

    private func transcriptURLs(modifiedAfter cutoff: Date) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            // A file untouched since before the window can only hold entries
            // older than the window, so it never needs opening at all.
            guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
            // Unchanged since the last pass? Nothing was appended.
            if let cursor = cursors[url.path], cursor.modified == modified { continue }
            out.append(url)
        }
        return out
    }

    private func scan(_ url: URL) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var start = cursors[url.path]?.offset ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        // Truncated or replaced (a session file rewritten from scratch): start over
        // rather than reading from a byte offset that now means something else.
        if size < start { start = 0; }

        guard size > start else {
            cursors[url.path] = FileCursor(offset: size, modified: modified)
            return
        }

        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Only advance the cursor to the last complete line. A transcript being
        // written right now can end mid-line, and half a JSON object parsed as a
        // whole one is a silently dropped turn.
        var consumed = data.count
        if data.last != UInt8(ascii: "\n") {
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                consumed = lastNewline + 1
            } else {
                consumed = 0   // no complete line yet; wait for more
            }
        }
        guard consumed > 0 else { return }

        let complete = data.prefix(consumed)
        for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            ingest(line)
        }
        cursors[url.path] = FileCursor(offset: start + UInt64(consumed), modified: modified)
    }

    /// Cheap byte-level prefilter: a turn we care about always carries these.
    private static let usageMarker = Array("\"usage\"".utf8)

    private func ingest(_ line: Data.SubSequence) {
        guard contains(line, Self.usageMarker) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }

        // `requestId` is the stable identity of one API call; fall back to the
        // message id, and finally to the record uuid, so a log shape that drops
        // one of them degrades to over-counting nothing rather than everything.
        let key = (obj["requestId"] as? String)
            ?? (message["id"] as? String)
            ?? (obj["uuid"] as? String)
            ?? UUID().uuidString
        guard seenRequests.insert(key).inserted else { return }

        guard let stamp = obj["timestamp"] as? String, let date = Self.parseDate(stamp) else { return }

        let totals = TokenTotals(
            input: int(usage["input_tokens"]),
            output: int(usage["output_tokens"]),
            cacheRead: int(usage["cache_read_input_tokens"]),
            cacheWrite: int(usage["cache_creation_input_tokens"]))
        guard totals.total > 0 else { return }

        entries.append(Entry(day: Calendar.current.startOfDay(for: date),
                             project: Self.projectName(obj["cwd"] as? String),
                             totals: totals))
    }

    // MARK: - Assembly

    private func assemble(cutoff: Date) -> HistorySnapshot {
        var byDay: [Date: TokenTotals] = [:]
        var byProject: [String: TokenTotals] = [:]
        for e in entries {
            byDay[e.day, default: TokenTotals()] = byDay[e.day, default: TokenTotals()] + e.totals
            byProject[e.project, default: TokenTotals()] = byProject[e.project, default: TokenTotals()] + e.totals
        }

        // Fill gaps so a quiet day is a visible zero, not a missing bar.
        var days: [(Date, TokenTotals)] = []
        var cursor = cutoff
        let today = Calendar.current.startOfDay(for: Date())
        while cursor <= today {
            days.append((cursor, byDay[cursor] ?? TokenTotals()))
            cursor = Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
        }

        var snapshot = HistorySnapshot()
        snapshot.days = days.map { (day: $0.0, totals: $0.1) }
        snapshot.projects = byProject
            .map { (name: $0.key, totals: $0.value) }
            .sorted { $0.totals.total > $1.totals.total }
        snapshot.windowDays = windowDays
        return snapshot
    }

    // MARK: - Helpers

    private func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    private func contains(_ haystack: Data.SubSequence, _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return haystack.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let limit = raw.count - needle.count
            var i = 0
            while i <= limit {
                if base[i] == needle[0] && memcmp(base + i, needle, needle.count) == 0 { return true }
                i += 1
            }
            return false
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    /// `/Users/me/Documents/GitHub/Capitally` → "Capitally".
    private static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }
}
