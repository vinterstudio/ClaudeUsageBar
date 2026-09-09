import AppKit

/// Menu bar app showing the current Claude Code session usage percentage.
/// Polls the OAuth usage endpoint (no model tokens) on a timer, reconstructs a
/// 30-day token history from Claude Code's own transcript logs, and can
/// optionally mirror all of it into the MacBook's notch.
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let auth = Auth()
    private let usage = UsageClient()
    private var timer: Timer?

    // Menu items we update live.
    private let statusLine = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    private let detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let historyLine = NSMenuItem(title: "History: reading logs…", action: nil, keyEquivalent: "")
    private let projectsLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let notchItem = NSMenuItem(title: "Show in Notch", action: nil, keyEquivalent: "")
    /// Only shown when a notch exists but the current resolution hides it.
    private let notchHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    // Usage barely changes minute-to-minute, and these endpoints rate-limit
    // aggressive polling. 5 minutes is plenty and keeps us well clear of 429s.
    private let pollInterval: TimeInterval = 300

    // When rate-limited (HTTP 429), stop fetching until this time. Grows on
    // repeated 429s so we back off instead of hammering.
    private var backoffUntil: Date?
    private var backoffStep: TimeInterval = 0

    /// Whether a usage response has ever rendered. The stale-token path stays
    /// silent to preserve the last good value — but on a cold start there is no
    /// last good value, and staying silent leaves the launch placeholder up
    /// forever with no explanation of why.
    private var hasRenderedUsage = false

    // MARK: History

    private let history = HistoryStore()
    /// All history scanning happens here, serially — the store is not
    /// thread-safe and a scan can take a moment on the first, full pass.
    private let historyQueue = DispatchQueue(label: "com.vinterstudio.claudeusagebar.history",
                                             qos: .utility)
    private var historyTimer: Timer?
    /// Logs are appended constantly but the daily shape moves slowly.
    private let historyInterval: TimeInterval = 120

    // MARK: Notch

    private let activity = ActivityMonitor()
    private var notch: NotchWindow?
    /// Repaints the notch while Claude is busy, to drive the pulse.
    private var pulseTimer: Timer?
    private var model = NotchModel()

    private static let notchDefaultsKey = "ShowInNotch"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CC …"

        let menu = NSMenu()
        for item in [statusLine, detailLine, historyLine, projectsLine, updatedLine] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        notchItem.action = #selector(toggleNotch)
        notchItem.state = UserDefaults.standard.bool(forKey: Self.notchDefaultsKey) ? .on : .off
        // The overlay works on every display now: it hugs a real notch where one
        // is addressable, and hangs below the menu bar as a pill where it isn't.
        // So the toggle is never disabled — only its label changes, to say which
        // presentation the current display will get.
        switch NotchGeometry.availability() {
        case .available:
            notchItem.title = "Show in Notch"
        case .hiddenByResolution(let current, let suggestion):
            notchItem.title = "Show Overlay (pill — notch unusable at \(current))"
            notchHintItem.title = suggestion.map { "Switch to \($0) to use the notch itself" } ?? ""
            notchHintItem.isHidden = notchHintItem.title.isEmpty
        case .noNotch:
            notchItem.title = "Show Overlay (pill)"
        }
        menu.addItem(notchItem)
        notchHintItem.isEnabled = false
        notchHintItem.isHidden = true
        menu.addItem(notchHintItem)
        menu.addItem(NSMenuItem(title: "Install Claude Code Hooks…",
                                action: #selector(installHooks), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Reveal Raw Response", action: #selector(revealRaw), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu

        activity.onChange = { [weak self] state in self?.activityChanged(state) }
        activity.start()

        Task { await self.update() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.update() }
        }

        refreshHistory()
        historyTimer = Timer.scheduledTimer(withTimeInterval: historyInterval, repeats: true) { [weak self] _ in
            self?.refreshHistory()
        }

        if notchItem.state == .on { showNotch() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        activity.stop()
    }

    // MARK: - Menu actions

    /// Menu "Refresh Now" — bypasses any active backoff.
    @objc private func refreshNow() {
        Task { await self.update(userInitiated: true) }
        refreshHistory()
    }

    @objc private func revealRaw() {
        NSWorkspace.shared.selectFile(UsageClient.rawLogPath, inFileViewerRootedAtPath: "")
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    /// A resolution change can flip the presentation between notch and pill, so
    /// re-lay out and refresh the menu label rather than assuming the mode holds.
    @objc private func screensChanged() {
        notch?.layout()
        switch NotchGeometry.availability() {
        case .available:
            notchItem.title = "Show in Notch"
            notchHintItem.isHidden = true
        case .hiddenByResolution(let current, let suggestion):
            notchItem.title = "Show Overlay (pill — notch unusable at \(current))"
            notchHintItem.title = suggestion.map { "Switch to \($0) to use the notch itself" } ?? ""
            notchHintItem.isHidden = notchHintItem.title.isEmpty
        case .noNotch:
            notchItem.title = "Show Overlay (pill)"
            notchHintItem.isHidden = true
        }
    }

    @objc private func toggleNotch() {
        let on = notchItem.state != .on
        notchItem.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: Self.notchDefaultsKey)
        if on { showNotch() } else { hideNotch() }
    }

    /// Points the user at the hook installer rather than editing their
    /// `~/.claude/settings.json` behind their back — it is their config file,
    /// and a silent rewrite of it is exactly the kind of surprise this app
    /// already avoids with the keychain.
    @objc private func installHooks() {
        let alert = NSAlert()
        alert.messageText = "Install Claude Code hooks?"
        alert.informativeText = """
        Live activity in the notch needs a hook script registered with Claude Code. \
        The installer adds entries to ~/.claude/settings.json (backing the file up first) \
        that post an event to this app's local socket when Claude starts thinking, runs a \
        tool, or finishes.

        No prompt text or file contents are sent — only the event name, session id and tool name.

        Run:  ./hooks/install-hooks.sh
        """
        alert.addButton(withTitle: "Reveal Installer")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let path = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("hooks/install-hooks.sh").path
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Notch

    private func showNotch() {
        guard notch == nil else { return }
        let w = NotchWindow()
        w.model = model
        w.orderFrontRegardless()
        notch = w
    }

    private func hideNotch() {
        notch?.orderOut(nil)
        notch = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func activityChanged(_ state: ActivityState) {
        model.activity = state
        notch?.model = model
        // Only run a repaint ticker while there is something moving to draw.
        if state.isBusy, notch != nil, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                self?.notch?.contentView?.needsDisplay = true
            }
        } else if !state.isBusy {
            pulseTimer?.invalidate()
            pulseTimer = nil
            notch?.contentView?.needsDisplay = true
        }
    }

    // MARK: - History

    private func refreshHistory() {
        historyQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.history.refresh()
            DispatchQueue.main.async { self.renderHistory(snapshot) }
        }
    }

    @MainActor
    private func renderHistory(_ snapshot: HistorySnapshot) {
        model.history = snapshot
        notch?.model = model

        let total = snapshot.grandTotal
        if total.total == 0 {
            historyLine.title = "History: no turns in the last \(snapshot.windowDays) days"
            projectsLine.title = ""
            return
        }
        historyLine.title = "Last \(snapshot.windowDays)d: \(compact(total.total)) fresh tokens"
            + "  (in \(compact(total.input + total.cacheWrite)) · out \(compact(total.output))"
            + " · \(compact(total.cacheRead)) read from cache)"
        projectsLine.title = "Top: " + snapshot.projects.prefix(3)
            .map { "\($0.name) \(compact($0.totals.total))" }
            .joined(separator: "   ")
    }

    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    // MARK: - Usage polling

    @MainActor
    private func update(userInitiated: Bool = false) async {
        // Honour an active backoff window (unless the user explicitly hit Refresh Now).
        if let until = backoffUntil, Date() < until, !userInitiated {
            return
        }
        // Primary source: the file the desktop app already maintains. It needs no
        // credentials, makes no network call, and — decisively for this app —
        // cannot raise a keychain prompt. The OAuth endpoint below is now only a
        // fallback for a machine where that file does not exist.
        if let snapshot = PlanUsageFile.snapshot() {
            render(snapshot, source: .planFile)
            return
        }

        do {
            let token = try auth.validAccessToken()
            let snapshot = try await usage.fetch(accessToken: token)
            backoffUntil = nil
            backoffStep = 0
            render(snapshot, source: .oauth)
        } catch AuthError.staleToken {
            // Claude Code hasn't refreshed its token yet. Don't refresh it
            // ourselves (that would desync Claude Code) and don't flash an
            // error — keep showing the last value until Claude Code rotates it.
            // With no last value to keep, say so rather than sitting on "CC …".
            if !hasRenderedUsage { renderStaleToken() }
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

    enum UsageSource { case planFile, oauth }

    @MainActor
    private func render(_ snapshot: UsageSnapshot, source: UsageSource) {
        let session = snapshot.windows.first { $0.label == "5h" } ?? snapshot.primary
        let weekly  = snapshot.windows.first { $0.label == "7d" }

        model.session = session
        model.weekly = weekly
        model.statusNote = nil
        notch?.model = model
        hasRenderedUsage = true

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
        let resets = resetDescription(session: session, weekly: weekly)
        detailLine.title = resets.isEmpty
            ? (session.percent == 0
                ? "No active session window"
                : "Session reset time not derivable from the sample history")
            : resets

        let t = DateFormatter(); t.timeStyle = .medium
        switch source {
        case .planFile:
            // Report when the desktop app last sampled, not when we read the file
            // — the number is only ever as fresh as that sample.
            let sampled = PlanUsageFile.lastModified.map { t.string(from: $0) } ?? "unknown"
            updatedLine.title = "Sampled \(sampled) — from Claude desktop app"
        case .oauth:
            updatedLine.title = "Updated \(t.string(from: Date()))"
        }
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
            // An estimate is marked as one. The plan-usage file reports no reset
            // times, so this is derived from the sample series and is only as
            // precise as the sampling interval.
            let mark = w.resetIsEstimated ? "≈" : ""
            return "\(label) resets \(mark)\(Self.clock.string(from: r)) (in \(remaining))"
        }

        var parts = [line("Session", session), weekly.flatMap { line("Weekly", $0) }]
            .compactMap { $0 }
        if session.resetIsEstimated {
            let mins = Int((PlanUsageFile.samplingUncertainty() / 60).rounded())
            parts.append("estimated ±\(mins) min")
        }
        return parts.joined(separator: "   ·   ")
    }

    /// Cold start with a token Claude Code has not yet rotated. Nothing is
    /// broken and there is nothing for the user to fix — the number appears on
    /// its own once Claude Code makes its next request — so this explains the
    /// wait instead of reading as a failure.
    @MainActor
    private func renderStaleToken() {
        statusItem.button?.title = "CC ⏳"
        statusLine.title = "Waiting for Claude Code to refresh its token"
        detailLine.title = "The percentage appears once Claude Code next makes a request."
        model.statusNote = "Waiting for token"
        notch?.model = model
        let t = DateFormatter(); t.timeStyle = .medium
        updatedLine.title = "Checked \(t.string(from: Date()))"
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
        model.statusNote = "Rate-limited"
        notch?.model = model
        let full = DateFormatter(); full.timeStyle = .medium
        updatedLine.title = "Last try \(full.string(from: Date()))"
    }

    @MainActor
    private func renderError(_ error: Error) {
        statusItem.button?.title = "CC —"
        switch error {
        case AuthError.noCredentials:
            statusLine.title = "Not signed in to Claude Code"
            model.statusNote = "Not signed in"
        case UsageError.http(let code, _):
            statusLine.title = "Usage request failed (HTTP \(code))"
            model.statusNote = "HTTP \(code)"
        default:
            statusLine.title = "Error"
            detailLine.title = String("\(error)".prefix(120))
            model.statusNote = "Error"
        }
        notch?.model = model
        let t = DateFormatter(); t.timeStyle = .medium
        updatedLine.title = "Tried \(t.string(from: Date()))"
    }
}

// Health report: why the number or the notch might not be showing. Prints no
// token material. `--doctor` exists so this is a check that can be re-run rather
// than a diagnosis that has to be repeated by hand.
if CommandLine.arguments.contains("--doctor") {
    print("ClaudeUsageBar doctor\n")

    if PlanUsageFile.exists, let snapshot = PlanUsageFile.snapshot() {
        let sampled = PlanUsageFile.lastModified.map { "\($0)" } ?? "unknown"
        let session = snapshot.windows.first { $0.label == "5h" }?.percent ?? -1
        let weekly = snapshot.windows.first { $0.label == "7d" }?.percent ?? -1
        print("source: plan-usage-history.json (PRIMARY, no credentials needed)")
        print("  session \(session)%, weekly \(weekly)%, \(PlanUsageFile.samples().count) samples,"
              + " last sampled \(sampled)")
        print("credentials: not consulted — the plan-usage file covers this machine.")
        print("  (Pass --check-credentials to inspect the keychain item. That reads the")
        print("   secret and can raise a keychain prompt, so it is opt-in.)")
    } else {
        print("source: plan-usage-history.json MISSING — falling back to the OAuth endpoint")
    }

    // Reading the secret is the ONE operation here that can prompt for a keychain
    // password, so it happens only when it can actually change the diagnosis:
    // the plan file is missing, or the user explicitly asked.
    if !PlanUsageFile.exists || CommandLine.arguments.contains("--check-credentials") {
    switch Auth().status() {
    case .ok(let expiresAt, let subscription):
        print("credentials: OK (expire \(expiresAt), plan \(subscription ?? "unknown"))")
    case .expired(let since, let subscription):
        print("credentials: EXPIRED since \(since) (plan \(subscription ?? "unknown"))")
        print("  Only matters if the plan-usage file above is missing.")
        print("  Note: as of 2026-09 this item can exist with EMPTY token strings and")
        print("  expiresAt 0 — Claude Code moved its credentials to the Electron")
        print("  'Claude Safe Storage' key. Running `claude` rewrites the item but does")
        print("  not repopulate it, so the OAuth path cannot be revived that way.")
    case .missing:
        print("credentials: MISSING — not signed in to the Claude Code CLI.")
    }
    }

    // The credential JSON's shape has changed before (2026-09-09: `expiresAt`
    // arrived as 0, which decoded silently and dated the token to 1970). Print
    // the STRUCTURE — keys and value types only, every value redacted — so a
    // format change is diagnosable without a single secret reaching the output.
    if CommandLine.arguments.contains("--shape") {
        print("\ncredential item shape (values redacted):")
        if let raw = Keychain.readRaw(),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func describe(_ any: Any) -> String {
                switch any {
                case let s as String: return "String(len \(s.count))"
                case let n as NSNumber:
                    // Numbers are the one thing safe to show: they are timestamps
                    // and flags here, never secret material.
                    return "Number(\(n))"
                case let a as [Any]: return "Array(\(a.count))"
                case is [String: Any]: return "Object"
                default: return "\(type(of: any))"
                }
            }
            func walk(_ dict: [String: Any], indent: String) {
                for key in dict.keys.sorted() {
                    let value = dict[key]!
                    print("\(indent)\(key): \(describe(value))")
                    if let nested = value as? [String: Any] { walk(nested, indent: indent + "  ") }
                }
            }
            walk(obj, indent: "  ")
        } else {
            print("  (could not read or parse the item)")
        }
    }

    switch NotchGeometry.availability() {
    case .available(let width):
        print("notch: available (\(Int(width))pt wide)")
    case .hiddenByResolution(let current, let suggestion):
        print("notch: present in hardware but HIDDEN at \(current)")
        print("  This mode has no taller sibling, so macOS runs the menu bar below the")
        print("  notch and reports no safe-area inset.")
        if let suggestion { print("  Fix: System Settings > Displays > \(suggestion)") }
    case .noNotch:
        print("notch: no notched display")
    }

    let h = HistoryStore().refresh()
    let t = h.grandTotal
    print("history: \(h.days.count) days, \(t.total) fresh tokens, \(t.cacheRead) cache reads,"
          + " \(h.projects.count) projects")
    print("activity socket: \(FileManager.default.fileExists(atPath: ActivityMonitor.socketPath) ? "present" : "absent") at \(ActivityMonitor.socketPath)")
    exit(0)
}

// Verification entry point: render the notch to PNGs and exit, so the drawing
// code can be checked without a display or screen-recording permission.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-notch"), i + 1 < args.count {
    var m = NotchModel()
    // Use the REAL snapshot where available. Hardcoded sample values have now
    // twice hidden a defect that only existed with live data — a clipped figure
    // and a wrong-height strip — so the sample renders what actually ships.
    if let live = PlanUsageFile.snapshot() {
        m.session = live.windows.first { $0.label == "5h" }
        m.weekly = live.windows.first { $0.label == "7d" }
    } else {
        m.session = UsageWindow(label: "5h", percent: 41,
                                resetsAt: Date().addingTimeInterval(3600 * 2))
        m.weekly = UsageWindow(label: "7d", percent: 68,
                               resetsAt: Date().addingTimeInterval(86400 * 3))
    }
    m.activity = .working(session: "abc12345", tool: "Bash")
    m.history = HistoryStore().refresh()
    try NotchWindow.renderSamples(model: m, to: args[i + 1])
    print("Rendered notch samples to \(args[i + 1])")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
let controller = AppController()
app.delegate = controller
app.run()
