import Foundation

/// What Claude Code is doing right now, as reported by its hooks.
enum ActivityState: Equatable {
    case idle                       // nothing running, or nothing has reported in
    case thinking(session: String)  // a prompt was submitted, no tool yet
    case working(session: String, tool: String)
    case waiting(session: String)   // Claude is asking the user something
    case done(session: String)      // finished a turn; decays back to .idle

    var isBusy: Bool {
        switch self {
        case .thinking, .working: return true
        case .idle, .waiting, .done: return false
        }
    }

    /// Short label for the collapsed notch.
    var label: String {
        switch self {
        case .idle: return ""
        case .thinking: return "thinking"
        case .working(_, let tool): return tool.lowercased()
        case .waiting: return "needs you"
        case .done: return "done"
        }
    }
}

/// Listens on a Unix domain socket for one-line JSON events posted by the
/// Claude Code hook script (`hooks/notify-usage-bar.sh`).
///
/// The socket lives in the app's own Application Support directory with 0600
/// permissions, so only this user can write to it. Events are treated as
/// untrusted input: nothing in a payload is executed, and only a fixed set of
/// fields is read, each of them clamped for display.
final class ActivityMonitor {
    static var socketPath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.sock").path
    }()

    /// Called on the main queue whenever the state changes.
    var onChange: ((ActivityState) -> Void)?

    private(set) var state: ActivityState = .idle {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { self.onChange?(s) }
        }
    }

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.vinterstudio.claudeusagebar.activity")
    /// A finished turn shows "done" briefly, then falls back to idle.
    private var decayTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    func start() {
        queue.async { self.openSocket() }
    }

    func stop() {
        queue.async {
            self.source?.cancel()
            self.source = nil
            if self.listenFD >= 0 { close(self.listenFD); self.listenFD = -1 }
            unlink(Self.socketPath)
            self.state = .idle
        }
    }

    private func openSocket() {
        // A stale socket file from a crash would make bind() fail with EADDRINUSE.
        unlink(Self.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath
        // `sun_path` is a fixed-size C array; its capacity has to be read into a
        // local before we take a mutable pointer to the field itself.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { close(fd); return }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self),
                        src, capacity - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }

        // Only this user may post events.
        chmod(path, 0o600)

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // Hook payloads are tiny; one bounded read is enough and caps how much a
        // misbehaving writer can make us hold.
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(client, &buffer, buffer.count)
        guard n > 0 else { return }
        handle(Data(buffer[0..<n]))
    }

    // MARK: - Events

    private func handle(_ data: Data) {
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let event = obj["hook_event_name"] as? String
            else { continue }

            let session = Self.clean(obj["session_id"] as? String, limit: 8)
            let tool = Self.clean(obj["tool_name"] as? String, limit: 16)

            switch event {
            case "UserPromptSubmit", "SessionStart":
                cancelDecay()
                state = .thinking(session: session)
            case "PreToolUse":
                cancelDecay()
                state = .working(session: session, tool: tool.isEmpty ? "tool" : tool)
            case "PostToolUse":
                cancelDecay()
                state = .thinking(session: session)
            case "Notification":
                cancelDecay()
                state = .waiting(session: session)
            case "Stop", "SubagentStop":
                state = .done(session: session)
                scheduleDecay(after: 6)
            case "SessionEnd":
                cancelDecay()
                state = .idle
            default:
                continue
            }
        }
    }

    private func scheduleDecay(after seconds: Int) {
        cancelDecay()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(seconds))
        t.setEventHandler { [weak self] in
            self?.state = .idle
            self?.decayTimer = nil
        }
        t.resume()
        decayTimer = t
    }

    private func cancelDecay() {
        decayTimer?.cancel()
        decayTimer = nil
    }

    /// Hook payloads come from outside the app. Anything shown in the UI is
    /// truncated and stripped of control characters so a crafted field cannot
    /// reflow or spoof the notch.
    private static func clean(_ s: String?, limit: Int) -> String {
        guard let s else { return "" }
        let filtered = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(filtered)).prefix(limit).description
    }
}
