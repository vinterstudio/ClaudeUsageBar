import AppKit

/// Menu bar app showing the current Claude Code session usage percentage.
/// Polls the OAuth usage endpoint (no model tokens) on a timer.
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let auth = Auth()
    private let usage = UsageClient()
    private var timer: Timer?

    // Menu items we update live.
    private let statusLine = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    private let detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    // Usage barely changes minute-to-minute, and these endpoints rate-limit
    // aggressive polling. 5 minutes is plenty and keeps us well clear of 429s.
    private let pollInterval: TimeInterval = 300

    // When rate-limited (HTTP 429), stop fetching until this time. Grows on
    // repeated 429s so we back off instead of hammering.
    private var backoffUntil: Date?
    private var backoffStep: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CC …"

        let menu = NSMenu()
        statusLine.isEnabled = false
        detailLine.isEnabled = false
        updatedLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(detailLine)
        menu.addItem(updatedLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Reveal Raw Response", action: #selector(revealRaw), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu

        Task { await self.update() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.update() }
        }
    }

    /// Menu "Refresh Now" — bypasses any active backoff.
    @objc private func refreshNow() {
        Task { await self.update(userInitiated: true) }
    }

    @objc private func revealRaw() {
        NSWorkspace.shared.selectFile(UsageClient.rawLogPath, inFileViewerRootedAtPath: "")
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @MainActor
    private func update(userInitiated: Bool = false) async {
        // Honour an active backoff window (unless the user explicitly hit Refresh Now).
        if let until = backoffUntil, Date() < until, !userInitiated {
            return
        }
        do {
            let token = try auth.validAccessToken()
            let snapshot = try await usage.fetch(accessToken: token)
            backoffUntil = nil
            backoffStep = 0
            render(snapshot)
        } catch AuthError.staleToken {
            // Claude Code hasn't refreshed its token yet. Don't refresh it
            // ourselves (that would desync Claude Code) and don't flash an
            // error — keep showing the last value until Claude Code rotates it.
            return
        } catch UsageError.http(429, _) {
            // Exponential backoff: 5, 10, 20 … capped at 30 minutes.
            backoffStep = backoffStep == 0 ? 300 : min(backoffStep * 2, 1800)
            backoffUntil = Date().addingTimeInterval(backoffStep)
            renderRateLimited()
        } catch {
            renderError(error)
        }
    }

    /// 24-hour clock formatter (e.g. "02:00"), independent of system locale.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return f
    }()

    @MainActor
    private func render(_ snapshot: UsageSnapshot) {
        let session = snapshot.windows.first { $0.label == "5h" } ?? snapshot.primary
        let weekly  = snapshot.windows.first { $0.label == "7d" }

        guard let session else {
            statusItem.button?.title = "CC ?"
            statusLine.title = "No usage data"
            return
        }

        // Compact menu-bar title, e.g. "S 19% · W 25% · 02:00"
        // S = current session (5h), W = weekly (7d), then the session reset time.
        var bar = "S \(session.percent)%"
        if let w = weekly { bar += " · W \(w.percent)%" }
        if let reset = session.resetsAt { bar += " · \(Self.clock.string(from: reset))" }
        statusItem.button?.title = bar

        // Dropdown: spelled-out detail.
        statusLine.title = "Session: \(session.percent)% used" + (weekly.map { "   Weekly: \($0.percent)% used" } ?? "")
        detailLine.title = resetDescription(session: session, weekly: weekly)

        let t = DateFormatter(); t.timeStyle = .medium
        updatedLine.title = "Updated \(t.string(from: Date()))"
    }

    /// Builds the dropdown reset line with both 24h clock times and countdowns.
    private func resetDescription(session: UsageWindow, weekly: UsageWindow?) -> String {
        let dur = DateComponentsFormatter()
        dur.allowedUnits = [.day, .hour, .minute]
        dur.unitsStyle = .abbreviated
        dur.maximumUnitCount = 2

        func line(_ label: String, _ w: UsageWindow) -> String? {
            guard let r = w.resetsAt else { return nil }
            let remaining = dur.string(from: max(0, r.timeIntervalSinceNow)) ?? ""
            return "\(label) resets \(Self.clock.string(from: r)) (in \(remaining))"
        }
        return [line("Session", session), weekly.flatMap { line("Weekly", $0) }]
            .compactMap { $0 }
            .joined(separator: "   ·   ")
    }

    @MainActor
    private func renderRateLimited() {
        // Keep the menu-bar number and detail line (last good data) intact;
        // just note in the status line that we're backing off.
        let t = DateFormatter(); t.timeStyle = .short
        if let until = backoffUntil {
            statusLine.title = "Rate-limited — retrying after \(t.string(from: until))"
        } else {
            statusLine.title = "Rate-limited — backing off"
        }
        let full = DateFormatter(); full.timeStyle = .medium
        updatedLine.title = "Last try \(full.string(from: Date()))"
    }

    @MainActor
    private func renderError(_ error: Error) {
        statusItem.button?.title = "CC —"
        switch error {
        case AuthError.noCredentials:
            statusLine.title = "Not signed in to Claude Code"
        case UsageError.http(let code, _):
            statusLine.title = "Usage request failed (HTTP \(code))"
        default:
            statusLine.title = "Error"
            detailLine.title = String("\(error)".prefix(120))
        }
        let t = DateFormatter(); t.timeStyle = .medium
        updatedLine.title = "Tried \(t.string(from: Date()))"
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
let controller = AppController()
app.delegate = controller
app.run()
