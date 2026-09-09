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

    /// Collapsed height matches the menu bar so the wings sit level with it.
    private let collapsedHeight: CGFloat = 24
    private let expandedHeight: CGFloat = 358
    private let expandedWidth: CGFloat = 460
    /// How far past the notch the collapsed wings extend on each side.
    private let wingWidth: CGFloat = 88

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
        let notch = NotchGeometry.notchWidth(of: screen) ?? 200
        content.notchWidth = notch
        content.isExpanded = isExpanded

        let width = isExpanded ? max(expandedWidth, notch + 2 * wingWidth) : notch + 2 * wingWidth
        let height = isExpanded ? expandedHeight : collapsedHeight
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.maxY - height,
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
    var notchWidth: CGFloat = 200
    var isExpanded = false

    override var isFlipped: Bool { true }

    private let ink = NSColor.white
    private let dim = NSColor.white.withAlphaComponent(0.55)
    private let faint = NSColor.white.withAlphaComponent(0.18)

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        if isExpanded { drawExpanded() } else { drawCollapsed() }
    }

    // MARK: Collapsed

    /// Two "wings" flanking the physical notch, painted the same black so they
    /// read as an extension of it rather than a floating window.
    private func drawCollapsed() {
        let wing = (bounds.width - notchWidth) / 2
        guard wing > 0 else { return }

        let left = NSRect(x: 0, y: 0, width: wing, height: bounds.height)
        let right = NSRect(x: bounds.width - wing, y: 0, width: wing, height: bounds.height)
        for (rect, corner) in [(left, true), (right, false)] {
            let path = NSBezierPath()
            let r: CGFloat = 8
            if corner {
                // Left wing: rounded on its outer (left) bottom corner only.
                path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
                path.line(to: NSPoint(x: rect.minX, y: rect.minY))
                path.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))
                path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
                               radius: r, startAngle: 180, endAngle: 90, clockwise: true)
                path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            } else {
                path.move(to: NSPoint(x: rect.minX, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
                path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
                               radius: r, startAngle: 0, endAngle: 90, clockwise: false)
                path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            }
            path.close()
            NSColor.black.setFill()
            path.fill()
        }

        // Left wing: session %. Right wing: weekly %, or the live activity when
        // Claude is doing something — that is the more interesting fact.
        let leftText = model.session.map { "S \($0.percent)%" } ?? "S —"
        draw(leftText, in: left.insetBy(dx: 8, dy: 4), align: .left, size: 11,
             color: colour(for: model.session?.percent))

        if model.activity != .idle {
            draw(model.activity.label, in: right.insetBy(dx: 8, dy: 4), align: .right, size: 10,
                 color: model.activity.isBusy ? NSColor.systemGreen : dim)
            if model.activity.isBusy { drawPulse(in: right) }
        } else {
            let rightText = model.weekly.map { "W \($0.percent)%" } ?? ""
            draw(rightText, in: right.insetBy(dx: 8, dy: 4), align: .right, size: 11,
                 color: colour(for: model.weekly?.percent))
        }
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
        // with the screen edge so it appears to grow out of the notch.
        let path = NSBezierPath()
        let r: CGFloat = 18
        let b = bounds
        path.move(to: NSPoint(x: b.minX, y: b.minY))
        path.line(to: NSPoint(x: b.minX, y: b.maxY - r))
        path.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.maxY - r), radius: r,
                       startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: b.maxX - r, y: b.maxY))
        path.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.maxY - r), radius: r,
                       startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: b.maxX, y: b.minY))
        path.close()
        NSColor.black.withAlphaComponent(0.93).setFill()
        path.fill()
        faint.setStroke()
        path.lineWidth = 1
        path.stroke()

        var y: CGFloat = 14
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
            if let reset = w?.resetsAt {
                draw("resets \(Self.resetLabel(reset))",
                     in: NSRect(x: rect.minX, y: rect.minY + 14, width: rect.width, height: 24),
                     align: .right, size: 10, color: dim)
            }
        }

        cell(left, "SESSION (5H)", model.session)
        cell(right, "WEEKLY (7D)", model.weekly)
        return top + 64
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
        let notchWidth = NotchGeometry.preferredScreen.flatMap { NotchGeometry.notchWidth(of: $0) } ?? 200
        for (name, expanded, size) in [
            ("notch-collapsed", false, NSSize(width: notchWidth + 176, height: 24)),
            ("notch-expanded",  true,  NSSize(width: 460, height: 358)),
        ] {
            let view = NotchContentView(frame: NSRect(origin: .zero, size: size))
            view.model = model
            view.notchWidth = notchWidth
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
