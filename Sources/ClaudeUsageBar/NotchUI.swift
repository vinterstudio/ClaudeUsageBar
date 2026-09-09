import AppKit

/// Everything the notch draws, in one value so the view never reaches back
/// into the controller.
struct NotchModel {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var history = HistorySnapshot()
    var activity: ActivityState = .idle
    var statusNote: String?          // "Rate-limited", "Not signed in", …
}

// MARK: - Geometry

/// Where the notch is on a given screen, if it has one.
enum NotchGeometry {
    /// Width of the physical notch in points, or nil on a screen without one.
    static func notchWidth(of screen: NSScreen) -> CGFloat? {
        // `safeAreaInsets.top` is non-zero only on a display whose menu bar is
        // interrupted by a notch, which is exactly the condition we want.
        guard screen.safeAreaInsets.top > 0 else { return nil }
        let left = screen.auxiliaryTopLeftArea?.width
        let right = screen.auxiliaryTopRightArea?.width
        guard let left, let right else { return nil }
        let width = screen.frame.width - left - right
        return width > 0 ? width : nil
    }

    static var hasNotch: Bool {
        NSScreen.screens.contains { notchWidth(of: $0) != nil }
    }

    /// Why notch mode is or isn't available. "No notch" and "notch hidden by the
    /// current resolution" look identical through `safeAreaInsets` alone, and
    /// telling a user with a notched MacBook that they have no notched display
    /// is both wrong and unactionable.
    enum Availability {
        case available(width: CGFloat)
        /// Panel has a notch, but the selected mode runs the menu bar below it.
        case hiddenByResolution(current: String, suggestion: String?)
        case noNotch
    }

    /// A notched panel offers, for some widths, both a taller mode that extends
    /// beside the notch and a shorter one that sits below it — the pair differs
    /// by the notch height. A mode with no taller sibling (e.g. 1920x1200 on an
    /// M2 Air) therefore hides the notch, and `safeAreaInsets.top` reads 0.
    static func availability() -> Availability {
        if let screen = NSScreen.screens.first(where: { notchWidth(of: $0) != nil }),
           let width = notchWidth(of: screen) {
            return .available(width: width)
        }

        let id = CGMainDisplayID()
        guard let current = CGDisplayCopyDisplayMode(id) else { return .noNotch }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            return .noNotch
        }

        var heightsByWidth: [Int: Set<Int>] = [:]
        for m in modes { heightsByWidth[m.width, default: []].insert(m.height) }

        // Notch heights across the Apple lineup land in this range once scaled.
        let notchCapable = heightsByWidth.values.contains { heights in
            let sorted = heights.sorted()
            return sorted.indices.dropFirst().contains { (20...80).contains(sorted[$0] - sorted[$0 - 1]) }
        }
        guard notchCapable else { return .noNotch }

        // Suggest the tallest mode that does expose the notch.
        let suggestion = heightsByWidth
            .compactMap { width, heights -> (Int, Int)? in
                let sorted = heights.sorted()
                guard let taller = sorted.indices.dropFirst()
                    .first(where: { (20...80).contains(sorted[$0] - sorted[$0 - 1]) })
                else { return nil }
                return (width, sorted[taller])
            }
            .max { $0.0 < $1.0 }
            .map { "\($0.0)x\($0.1)" }

        return .hiddenByResolution(current: "\(current.width)x\(current.height)",
                                   suggestion: suggestion)
    }

    /// The screen the notch UI should live on: the built-in notched display.
    static var preferredScreen: NSScreen? {
        NSScreen.screens.first { notchWidth(of: $0) != nil } ?? NSScreen.main
    }
}

// MARK: - Window

/// A borderless overlay that hugs the notch. Collapsed it shows the two usage
/// figures either side of the notch cut-out; hovering expands it into a panel
/// with the 30-day history.
final class NotchWindow: NSPanel {
    private let content = NotchContentView()
    private var trackingArea: NSTrackingArea?
    private(set) var isExpanded = false

    /// How the overlay is presented on the current display.
    enum Mode {
        /// Wings flanking a real, addressable notch.
        case notch(width: CGFloat, height: CGFloat)
        /// No addressable notch (e.g. a scaled mode with no taller sibling):
        /// a rounded pill hanging just below the menu bar instead.
        case floating
    }

    private var mode: Mode = .floating

    /// Collapsed height for the floating pill. In notch mode the height comes
    /// from the display's own safe-area inset — hard-coding 24 left the wings
    /// short of a 56pt menu bar, with a visible seam beneath them.
    private let floatingHeight: CGFloat = 26
    private let floatingWidth: CGFloat = 190
    /// Height of the panel's usable content. The window itself is taller in
    /// notch mode by the height of the notch band, which is unusable — the panel
    /// is flush with the screen top, so its first rows sit BEHIND the notch.
    /// 371 leaves a 16pt margin below the last project row. Measured, not
    /// guessed: at 358 the final row's share bar ended 3pt from the edge and sat
    /// flush against it on the display.
    private let expandedContentHeight: CGFloat = 371
    private let expandedWidth: CGFloat = 460
    /// How far past the notch the collapsed wings extend on each side. Sized for
    /// "S 100% · W 100%" on the left wing at 12pt, the widest it can get.
    /// Static so the offscreen render uses the SAME value the window does — when
    /// the sample computed its own width it silently clipped the session figure.
    static let wingWidth: CGFloat = 124
    /// How far the collapsed shape extends below the notch, giving it something
    /// to merge with. Nothing can be drawn inside the notch itself — it is a
    /// camera housing, not display area — so the illusion depends entirely on
    /// this overhang sharing the notch's black.
    static let notchOverhang: CGFloat = 13

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar, so the panel can hang over it rather than under.
        level = .init(Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        // A menu-bar accessory must never steal focus from the app in front.
        becomesKeyOnlyIfNeeded = true
        contentView = content
        layout()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var model: NotchModel {
        get { content.model }
        set { content.model = newValue; content.needsDisplay = true }
    }

    func layout() {
        guard let screen = NotchGeometry.preferredScreen else { return }

        if let notch = NotchGeometry.notchWidth(of: screen) {
            // The notch strip is exactly as tall as the safe-area inset.
            mode = .notch(width: notch, height: screen.safeAreaInsets.top)
        } else {
            mode = .floating
        }
        content.mode = mode
        content.isExpanded = isExpanded

        let width: CGFloat
        let height: CGFloat
        let top: CGFloat

        switch mode {
        case .notch(let notchWidth, let notchHeight):
            width = isExpanded ? max(expandedWidth, notchWidth + 2 * Self.wingWidth)
                               : notchWidth + 2 * Self.wingWidth
            // Collapsed sits exactly on the notch band and paints no background,
            // so nothing protrudes over the desktop while idle. The overhang —
            // and the black form that merges with the notch — belongs to the
            // expanded panel, which appears on hover.
            height = isExpanded ? expandedContentHeight + notchHeight : notchHeight
            top = screen.frame.maxY
        case .floating:
            width = isExpanded ? expandedWidth : floatingWidth
            height = isExpanded ? expandedContentHeight : floatingHeight
            // Hang below the menu bar rather than under it: on a display with no
            // addressable notch the menu bar occupies the very top row, and an
            // overlay there would fight it for the same pixels.
            top = screen.frame.maxY - (screen.frame.maxY - screen.visibleFrame.maxY) - 4
        }

        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: top - height,
                           width: width,
                           height: height)
        setFrame(frame, display: true)
        content.frame = NSRect(origin: .zero, size: frame.size)
        rebuildTracking()
        content.needsDisplay = true
    }

    private func rebuildTracking() {
        if let existing = trackingArea { content.removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: content.bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        content.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setExpanded(true) }
    override func mouseExited(with event: NSEvent) { setExpanded(false) }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        layout()
    }
}

// MARK: - Drawing

final class NotchContentView: NSView {
    var model = NotchModel()
    var mode: NotchWindow.Mode = .floating
    var isExpanded = false

    /// Vertical space at the top of the panel that the notch covers.
    var notchBandHeight: CGFloat {
        if case .notch(_, let h) = mode { return h }
        return 0
    }

    /// Kept for the offscreen render entry point, which draws a sample notch.
    var notchWidth: CGFloat {
        if case .notch(let w, _) = mode { return w }
        return 200
    }

    override var isFlipped: Bool { true }

    private let ink = NSColor.white
    private let dim = NSColor.white.withAlphaComponent(0.55)
    private let faint = NSColor.white.withAlphaComponent(0.18)

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        if isExpanded { drawExpanded() } else {
            switch mode {
            case .notch: drawWings()
            case .floating: drawPill()
            }
        }
    }

    // MARK: Collapsed

    /// Two "wings" flanking the physical notch.
    ///
    /// Text only, level with the menu bar, no background — nothing should
    /// protrude over the desktop until the panel is opened.
    private func drawWings() {
        let wing = (bounds.width - notchWidth) / 2
        guard wing > 0 else { return }

        let left = NSRect(x: 0, y: 0, width: wing, height: bounds.height)
        let right = NSRect(x: bounds.width - wing, y: 0, width: wing, height: bounds.height)

        // BOTH quota windows live on the left wing, always. Weekly used to share
        // the right wing with the activity label, which meant it disappeared for
        // exactly as long as Claude was working — the moment you are most likely
        // to glance at it. Activity now has the right wing to itself.
        //
        // Each figure keeps its own colour coding, so they are drawn as separate
        // runs laid out right-to-left rather than as one joined string.
        let inset: CGFloat = 10
        var cursor = left.maxX - inset      // grow leftwards from the notch edge

        func place(_ text: String, size: CGFloat, color: NSColor) {
            guard !text.isEmpty else { return }
            let w = measure(text, size: size)
            drawCentred(text,
                        in: NSRect(x: cursor - w, y: left.minY, width: w, height: left.height),
                        align: .right, size: size, color: color)
            cursor -= w + 6
        }

        // Right-to-left: weekly sits nearest the notch, then a separator, then session.
        if let weekly = model.weekly {
            place("W \(weekly.percent)%", size: 12, color: colour(for: weekly.percent))
            place("·", size: 12, color: faint)
        }
        place(model.session.map { "S \($0.percent)%" } ?? "S —",
              size: 12, color: colour(for: model.session?.percent))

        // Activity on the right wing, hugging the notch: dot first, then label.
        guard model.activity != .idle else { return }
        if model.activity.isBusy { drawPulse(in: right) }
        let labelRect = NSRect(x: right.minX + 20, y: right.minY,
                               width: right.width - 26, height: right.height)
        drawCentred(model.activity.label, in: labelRect, align: .left, size: 11,
                    color: model.activity.isBusy ? NSColor.systemGreen : dim)
    }

    /// Rendered width of one run, so coloured segments can be laid out by hand.
    private func measure(_ text: String, size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Collapsed presentation with no notch to hug: a rounded pill under the menu
    /// bar. This is what a display running a mode with no addressable notch gets,
    /// and it is a deliberate design rather than a degraded one — the expanded
    /// panel is identical either way.
    private func drawPill() {
        let pill = bounds.insetBy(dx: 0, dy: 1)
        let path = NSBezierPath(roundedRect: pill,
                                xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSColor.black.withAlphaComponent(0.88).setFill()
        path.fill()
        faint.setStroke()
        path.lineWidth = 1
        path.stroke()

        let inner = pill.insetBy(dx: 14, dy: 0)
        if model.activity != .idle {
            // The pill puts both quota figures on ONE line, leaving no room for
            // the tool name, so activity is reduced to the pulsing dot — centred,
            // between the two numbers. Anchoring it to the pill's left edge (as
            // the wings do, where activity has a wing to itself) drew it straight
            // through the "S 41%" text.
            drawCentred(model.session.map { "S \($0.percent)%" } ?? "S —",
                        in: inner, align: .left, size: 12,
                        color: colour(for: model.session?.percent))
            drawCentred(model.weekly.map { "W \($0.percent)%" } ?? "",
                        in: inner, align: .right, size: 12,
                        color: colour(for: model.weekly?.percent))
            if model.activity.isBusy {
                drawPulse(in: NSRect(x: inner.midX - 12, y: inner.minY,
                                     width: 24, height: inner.height))
            }
        } else {
            drawCentred(model.session.map { "S \($0.percent)%" } ?? "S —",
                        in: inner, align: .left, size: 12,
                        color: colour(for: model.session?.percent))
            drawCentred(model.weekly.map { "W \($0.percent)%" } ?? "",
                        in: inner, align: .right, size: 12,
                        color: colour(for: model.weekly?.percent))
        }
    }

    /// Draws one line vertically centred in `rect`. The wings span the full menu
    /// bar height, so text has to be centred rather than pinned to the top.
    private func drawCentred(_ text: String, in rect: NSRect, align: NSTextAlignment,
                             size: CGFloat, color: NSColor) {
        guard !text.isEmpty else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        let line = NSRect(x: rect.minX, y: rect.midY - font.capHeight,
                          width: rect.width, height: font.ascender - font.descender)
        draw(text, in: line, align: align, size: size, color: color)
    }

    /// A small breathing dot, so "working" reads at a glance without animation
    /// frames. Driven by wall-clock time, redrawn by the controller's ticker.
    private func drawPulse(in rect: NSRect) {
        let phase = (sin(Date().timeIntervalSince1970 * 3) + 1) / 2
        let r: CGFloat = 2.5
        let center = NSPoint(x: rect.minX + 8, y: rect.midY)
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        NSColor.systemGreen.withAlphaComponent(0.35 + 0.65 * phase).setFill()
        dot.fill()
    }

    // MARK: Expanded

    private func drawExpanded() {
        // Panel body: rounded everywhere except the top edge, which stays flush
        // with the screen edge so it grows out of the notch.
        let path = Self.topFlushRoundedPath(in: bounds, radius: 18)
        NSColor.black.withAlphaComponent(0.93).setFill()
        path.fill()
        faint.setStroke()
        path.lineWidth = 1
        path.stroke()

        // Start BELOW the notch. The panel hangs from the top of the screen, so
        // its first rows are physically behind the camera housing: with a 250pt
        // notch centred in a 460pt panel, everything from x 105 to 355 in the
        // top band is invisible. That swallowed the reset time entirely and half
        // the weekly column. The band is left empty, which also gives the panel
        // the merged-with-the-notch look.
        var y: CGFloat = notchBandHeight + 14
        y = drawQuotaRow(top: y)
        y = drawActivityRow(top: y)
        y = drawChart(top: y)
        _ = drawProjects(top: y)
    }

    private func drawQuotaRow(top: CGFloat) -> CGFloat {
        let pad: CGFloat = 18
        let colWidth = (bounds.width - pad * 3) / 2
        let left = NSRect(x: pad, y: top, width: colWidth, height: 56)
        let right = NSRect(x: pad * 2 + colWidth, y: top, width: colWidth, height: 56)

        func cell(_ rect: NSRect, _ title: String, _ w: UsageWindow?) {
            draw(title, in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 14),
                 align: .left, size: 10, color: dim)
            let value = w.map { "\($0.percent)%" } ?? "—"
            draw(value, in: NSRect(x: rect.minX, y: rect.minY + 14, width: rect.width, height: 24),
                 align: .left, size: 20, weight: .semibold, color: colour(for: w?.percent))
            // Progress track.
            let bar = NSRect(x: rect.minX, y: rect.minY + 42, width: rect.width, height: 4)
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).setFillWithColor(faint)
            if let pct = w?.percent {
                let filled = NSRect(x: bar.minX, y: bar.minY,
                                    width: bar.width * CGFloat(pct) / 100, height: bar.height)
                NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2)
                    .setFillWithColor(colour(for: pct))
            }
            // Below the percentage and its bar, on its own line. It has now been
            // in two worse places: sharing the value line (dim, easy to miss)
            // and on the title line (right-aligned, which put it behind the
            // notch). Left-aligned under the bar it is clear of both.
            if let reset = w?.resetsAt {
                let mark = (w?.resetIsEstimated ?? false) ? "≈" : ""
                let left = Self.countdown.string(from: max(0, reset.timeIntervalSinceNow)) ?? ""
                draw("resets \(mark)\(Self.resetLabel(reset))  ·  \(left)",
                     in: NSRect(x: rect.minX, y: rect.minY + 52, width: rect.width, height: 14),
                     align: .left, size: 10, color: NSColor.white.withAlphaComponent(0.8))
            }
        }

        cell(left, "SESSION (5H)", model.session)
        cell(right, "WEEKLY (7D)", model.weekly)
        return top + 78
    }

    private func drawActivityRow(top: CGFloat) -> CGFloat {
        let pad: CGFloat = 18
        let rect = NSRect(x: pad, y: top, width: bounds.width - pad * 2, height: 16)
        let text: String
        switch model.activity {
        case .idle:              text = model.statusNote ?? "Idle"
        case .thinking:          text = "Claude is thinking…"
        case .working(_, let t): text = "Running \(t)…"
        case .waiting:           text = "Waiting for you"
        case .done:              text = "Finished a turn"
        }
        let dot = NSRect(x: rect.minX, y: rect.minY + 5, width: 6, height: 6)
        (model.activity.isBusy ? NSColor.systemGreen : dim).setFill()
        NSBezierPath(ovalIn: dot).fill()
        draw(text, in: rect.offsetBy(dx: 14, dy: 0), align: .left, size: 11, color: dim)
        return top + 24
    }

    /// 30-day token bars. Height is normalised to the busiest day in the window,
    /// so the shape shows relative intensity rather than an absolute scale that
    /// would flatten every quiet day to nothing.
    private func drawChart(top: CGFloat) -> CGFloat {
        let pad: CGFloat = 18
        let height: CGFloat = 90
        let rect = NSRect(x: pad, y: top + 16, width: bounds.width - pad * 2, height: height)

        let total = model.history.grandTotal.total
        draw("LAST \(model.history.windowDays) DAYS",
             in: NSRect(x: pad, y: top, width: rect.width, height: 14),
             align: .left, size: 10, color: dim)
        // "Fresh" is load-bearing: cache reads are excluded from the bars, and a
        // bare "tokens" here would not match a raw provider total.
        draw(total > 0 ? "\(Self.compact(total)) fresh · \(Self.compact(model.history.grandTotal.cacheRead)) cached" : "no data yet",
             in: NSRect(x: pad, y: top, width: rect.width, height: 14),
             align: .right, size: 10, color: dim)

        let days = model.history.days
        guard !days.isEmpty else { return top + height + 24 }
        let peak = max(1, model.history.busiestDay)
        let slot = rect.width / CGFloat(days.count)
        let barWidth = max(2, slot - 2)

        for (i, entry) in days.enumerated() {
            let ratio = CGFloat(entry.totals.total) / CGFloat(peak)
            let h = max(entry.totals.total > 0 ? 2 : 1, ratio * rect.height)
            let x = rect.minX + CGFloat(i) * slot
            let bar = NSRect(x: x, y: rect.maxY - h, width: barWidth, height: h)
            let isToday = Calendar.current.isDateInToday(entry.day)
            let colour = entry.totals.total == 0
                ? faint
                : (isToday ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.75))
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).setFillWithColor(colour)
        }

        // Endpoints only — 30 date labels would be unreadable at this width.
        let axis = NSRect(x: rect.minX, y: rect.maxY + 3, width: rect.width, height: 12)
        draw(Self.dayLabel.string(from: days.first!.day), in: axis, align: .left, size: 9, color: dim)
        draw("today", in: axis, align: .right, size: 9, color: dim)
        return rect.maxY + 26
    }

    private func drawProjects(top: CGFloat) -> CGFloat {
        let pad: CGFloat = 18
        draw("BY PROJECT", in: NSRect(x: pad, y: top, width: bounds.width - pad * 2, height: 14),
             align: .left, size: 10, color: dim)

        let rows = Array(model.history.projects.prefix(4))
        let grand = max(1, model.history.grandTotal.total)
        var y = top + 18
        for row in rows {
            let line = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 14)
            draw(row.name, in: line, align: .left, size: 11, color: ink)
            draw(Self.compact(row.totals.total), in: line, align: .right, size: 11, color: dim)
            // Share bar under the row.
            let share = CGFloat(row.totals.total) / CGFloat(grand)
            let track = NSRect(x: pad, y: y + 15, width: line.width, height: 2)
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).setFillWithColor(faint)
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                             width: track.width * share, height: track.height),
                         xRadius: 1, yRadius: 1)
                .setFillWithColor(NSColor.white.withAlphaComponent(0.6))
            y += 24
        }
        if rows.isEmpty {
            draw("Reading Claude Code logs…",
                 in: NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 14),
                 align: .left, size: 11, color: dim)
        }
        return y
    }

    // MARK: Helpers

    /// A rect rounded at the bottom and square at the top.
    ///
    /// Built by rounding ALL corners of a rect extended past the top edge, so
    /// the top corners fall outside the view and are clipped. The hand-rolled
    /// version used `appendArc(withCenter:startAngle:endAngle:clockwise:)`,
    /// whose angles are measured the other way round in a flipped view — it
    /// swept the bottom edge into a diagonal and pushed a black wedge out on
    /// one side. `NSBezierPath(roundedRect:)` is orientation-agnostic.
    static func topFlushRoundedPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        // Flipped view: minY is the TOP edge, so extending upward means -radius.
        let extended = NSRect(x: rect.minX, y: rect.minY - radius,
                              width: rect.width, height: rect.height + radius)
        return NSBezierPath(roundedRect: extended, xRadius: radius, yRadius: radius)
    }

    private func colour(for percent: Int?) -> NSColor {
        guard let percent else { return dim }
        switch percent {
        case ..<60:  return NSColor.systemGreen
        case ..<85:  return NSColor.systemYellow
        default:     return NSColor.systemRed
        }
    }

    private func draw(_ text: String, in rect: NSRect, align: NSTextAlignment,
                      size: CGFloat, weight: NSFont.Weight = .medium, color: NSColor) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let countdown: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    static let weekdayClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    /// The weekly window resets days away, and a bare "11:47" there reads as
    /// today. Anything beyond the next 24 hours carries its weekday.
    static func resetLabel(_ date: Date) -> String {
        date.timeIntervalSinceNow > 86_400
            ? weekdayClock.string(from: date)
            : clock.string(from: date)
    }

    static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f
    }()

    /// 1_234_567 → "1.2M". Keeps the panel's numbers scannable.
    /// Billions matter here: a month of cache reads runs to several of them, and
    /// without this case that printed as "3263.2M".
    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:         return String(format: "%.0fk", Double(n) / 1_000)
        default:               return "\(n)"
        }
    }
}

// MARK: - Offscreen render (verification)

extension NotchWindow {
    /// Renders both notch states to PNGs without a display, so the drawing code
    /// can be checked in a build step instead of by eye. Invoked with
    /// `ClaudeUsageBar --render-notch <dir>`.
    static func renderSamples(model: NotchModel, to directory: String) throws {
        let screen = NotchGeometry.preferredScreen
        let notchWidth = screen.flatMap { NotchGeometry.notchWidth(of: $0) } ?? 200
        // Height of a real notch strip, so the sample matches what ships rather
        // than a guess — 24 here hid a seam that only showed on the display.
        let notchHeight = screen.map { $0.safeAreaInsets.top > 0 ? $0.safeAreaInsets.top : 38 } ?? 38

        for (name, mode, expanded, size) in [
            ("notch-collapsed", Mode.notch(width: notchWidth, height: notchHeight), false,
             NSSize(width: notchWidth + 2 * wingWidth, height: notchHeight)),
            ("notch-floating", Mode.floating, false, NSSize(width: 190, height: 26)),
            // Rendered in notch mode so the sample reserves the same unusable
            // band the real panel does — a floating sample would hide exactly
            // the defect that put the reset time behind the notch.
            ("notch-expanded", Mode.notch(width: notchWidth, height: notchHeight), true,
             NSSize(width: 460, height: 371 + notchHeight)),
        ] {
            let view = NotchContentView(frame: NSRect(origin: .zero, size: size))
            view.model = model
            view.mode = mode
            view.isExpanded = expanded

            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            // The panel is drawn for a dark background; fill one first so the
            // PNG shows what sits over the desktop rather than transparency.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()

            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}

private extension NSBezierPath {
    func setFillWithColor(_ color: NSColor) {
        color.setFill()
        fill()
    }
}
