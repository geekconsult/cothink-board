import Foundation
import Combine
import Darwin

public struct ChatMessage: Identifiable, Equatable {
    public enum Role: String { case user, assistant, activity, error }
    public let id: UUID
    public let role: Role
    public var text: String
    public init(role: Role, text: String) { self.id = UUID(); self.role = role; self.text = text }
}

public enum ChatPhase: Equatable {
    case stopped, starting, ready, running, failed(String)
}

private final class SessionLease {
    private let lock = NSLock()
    private var descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    func release() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN); _ = close(descriptor); descriptor = -1
    }
    deinit { release() }
}

@MainActor
public final class PiChatController: ObservableObject {
    @Published public private(set) var phase: ChatPhase = .stopped
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var modelName = ""
    @Published public private(set) var bridgeReady = false
    @Published public private(set) var activityText = ""
    private var process: Process?
    private var sessionLease: SessionLease?
    private var input: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var generation = UUID()
    private var assistantID: UUID?
    private var readyPi = false
    private var historyRequested = false
    private var startupTask: Task<Void, Never>?
    public init() {}

    public func start(boardID: String, piPath: String, extensionPath: String, mcpPath: String, home: URL, extraEnvironment: [String: String] = [:]) {
        let previousProcess = process
        let previousLease = sessionLease
        stop()
        if let previousProcess, previousProcess.isRunning {
            let pendingGeneration = generation
            phase = .starting
            Task { [weak self] in
                await Task.detached {
                    previousProcess.waitUntilExit()
                    previousLease?.release()
                }.value
                guard let self, self.generation == pendingGeneration else { return }
                self.start(boardID: boardID, piPath: piPath, extensionPath: extensionPath, mcpPath: mcpPath, home: home, extraEnvironment: extraEnvironment)
            }
            return
        }
        previousLease?.release()
        messages = []; modelName = ""; bridgeReady = false; activityText = ""; readyPi = false; historyRequested = false
        guard FileManager.default.isExecutableFile(atPath: piPath) else { phase = .failed("Choose an executable Pi binary in chat settings."); return }
        guard FileManager.default.fileExists(atPath: extensionPath), FileManager.default.isExecutableFile(atPath: mcpPath) else { phase = .failed("CoThink's bundled Pi bridge or MCP server is missing. Rebuild the app."); return }
        let encodedID = Data(boardID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        let sessionDirectory = home.appendingPathComponent("AgentSessions", isDirectory: true).appendingPathComponent(encodedID, isDirectory: true)
        do { try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true) }
        catch { phase = .failed("Cannot create the local chat session: \(error.localizedDescription)"); return }
        let lockPath = sessionDirectory.appendingPathComponent(".session.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { phase = .failed("Cannot lock this board's Pi session. Check its folder permissions."); return }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            phase = .failed("This board's agent chat is already open in another window or app. Close it there and reconnect.")
            return
        }
        let lease = SessionLease(fd); sessionLease = lease
        let proc = Process(), inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        let runID = UUID(); generation = runID
        proc.executableURL = URL(fileURLWithPath: piPath)
        proc.arguments = ["--mode", "rpc", "--continue", "--session-dir", sessionDirectory.path, "--no-extensions", "--extension", extensionPath, "--no-builtin-tools", "--no-skills", "--no-prompt-templates", "--no-context-files", "--offline", "--append-system-prompt", "You are assisting with the current CoThink board. Use the CoThink tools to read context and make requested edits. Board ID: \(boardID). Obtain fresh revisions before edits. Do not claim actions succeeded if a tool returned an error."]
        var env = ProcessInfo.processInfo.environment
        env.merge(extraEnvironment) { _, new in new }
        env["COTHINK_PI_BOARD_ID"] = boardID
        env["COTHINK_MCP_PATH"] = mcpPath
        env["COTHINK_MCP_ACTOR"] = "pi"
        env["COTHINK_HOME"] = home.path
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = currentPath + ":/opt/homebrew/bin:/usr/local/bin"
        proc.environment = env
        proc.currentDirectoryURL = home
        proc.standardInput = inPipe; proc.standardOutput = outPipe; proc.standardError = errPipe
        do {
            phase = .starting
            try proc.run()
            process = proc; input = inPipe.fileHandleForWriting; stdout = outPipe.fileHandleForReading; stderr = errPipe.fileHandleForReading
            _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            attach(outPipe.fileHandleForReading, runID: runID, isError: false)
            attach(errPipe.fileHandleForReading, runID: runID, isError: true)
            proc.terminationHandler = { [weak self, lease] p in
                lease.release()
                Task { @MainActor [weak self] in self?.terminated(runID: runID, status: p.terminationStatus) }
            }
            sendCommand(["id": "startup", "type": "get_state"])
            startupTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.generation == runID, self.phase == .starting else { return }
                self.fail("Pi or the CoThink MCP bridge did not become ready. Check the Pi path and model setup.")
            }
        } catch { sessionLease?.release(); sessionLease = nil; phase = .failed("Unable to start Pi: \(error.localizedDescription)") }
    }

    public func send(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .ready, !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text)); assistantID = nil; activityText = "Starting…"; phase = .running
        sendCommand(["id": UUID().uuidString, "type": "prompt", "message": text])
    }
    public func cancel() { guard phase == .running else { return }; sendCommand(["type": "abort"]) }
    public func stop() {
        startupTask?.cancel(); startupTask = nil
        generation = UUID()
        stdout?.readabilityHandler = nil; stderr?.readabilityHandler = nil
        try? input?.close(); try? stdout?.close(); try? stderr?.close()
        if let process, process.isRunning { process.terminate() }
        else { sessionLease?.release() }
        process = nil; sessionLease = nil; input = nil; stdout = nil; stderr = nil
        phase = .stopped; bridgeReady = false; activityText = ""; readyPi = false
    }
    private func fail(_ message: String) {
        stop(); phase = .failed(message)
    }
    private func sendCommand(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object), var line = String(data: data, encoding: .utf8) else { fail("Unable to write to Pi."); return }
        line.append("\n")
        do { try input.write(contentsOf: Data(line.utf8)) } catch { fail("Pi connection closed: \(error.localizedDescription)") }
    }
    private func attach(_ handle: FileHandle, runID: UUID, isError: Bool) {
        let queue = DispatchQueue(label: "cothink.pi.lines.\(runID).\(isError)")
        var buffer = Data()
        handle.readabilityHandler = { [weak self] pipe in
            let data = pipe.availableData
            guard !data.isEmpty else { pipe.readabilityHandler = nil; return }
            queue.async {
                var start = data.startIndex
                while start < data.endIndex, let index = data[start...].firstIndex(of: 10) {
                    buffer.append(contentsOf: data[start..<index])
                    let line = buffer
                    buffer = Data()
                    start = data.index(after: index)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == runID else { return }
                        if isError { self.handleErrorLine(line) } else { self.handleLine(line) }
                    }
                }
                if start < data.endIndex { buffer.append(contentsOf: data[start...]) }
                if buffer.count > 96_000_000 {
                    buffer.removeAll()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == runID else { return }
                        self.fail("Pi sent an event larger than 96 MB. Reconnect and use a smaller image.")
                    }
                }
            }
        }
    }
    private func handleErrorLine(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix("COTHINK_MCP_READY") { bridgeReady = true; updateReadiness() }
        if text.hasPrefix("COTHINK_MCP_ERROR:") { fail(String(text.dropFirst("COTHINK_MCP_ERROR:".count)).trimmingCharacters(in: .whitespaces)) }
    }
    private func updateReadiness() {
        if readyPi && bridgeReady && phase == .starting && !historyRequested {
            historyRequested = true
            sendCommand(["id": "history", "type": "get_messages"])
        }
    }
    private func handleLine(_ line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = event["type"] as? String else { return }
        switch type {
        case "response":
            let command = event["command"] as? String ?? ""
            if (event["success"] as? Bool) == false {
                let error = event["error"] as? String ?? "Pi rejected \(command)."
                if command == "get_state" || command == "get_messages" { fail(error) } else { messages.append(ChatMessage(role: .error, text: error)); if phase == .running { phase = .ready } }
            } else if command == "get_state" {
                let state = event["data"] as? [String: Any]
                if let model = state?["model"] as? [String: Any] { modelName = model["name"] as? String ?? model["id"] as? String ?? "" }
                readyPi = true; updateReadiness()
            } else if command == "get_messages", phase == .starting {
                guard let data = event["data"] as? [String: Any], let previous = data["messages"] as? [[String: Any]] else { fail("Pi returned invalid chat history."); return }
                for item in previous {
                    guard let role = item["role"] as? String, ["user", "assistant"].contains(role) else { continue }
                    let parts = item["content"] as? [[String: Any]] ?? []
                    let text = (item["content"] as? String) ?? parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
                    if !text.isEmpty { messages.append(ChatMessage(role: role == "user" ? .user : .assistant, text: text)) }
                }
                startupTask?.cancel(); phase = .ready
            }
        case "message_start":
            if let message = event["message"] as? [String: Any], (message["role"] as? String) == "assistant" { assistantID = nil }
        case "agent_start":
            if phase == .running { setActivity("Thinking…", record: true) }
        case "message_update":
            if let delta = event["assistantMessageEvent"] as? [String: Any] {
                switch delta["type"] as? String {
                case "thinking_start", "thinking_delta":
                    if phase == .running { setActivity("Thinking…", record: true) }
                case "text_delta":
                    guard let text = delta["delta"] as? String else { return }
                    activityText = "Writing response…"
                    if let id = assistantID, let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text += text }
                    else { let message = ChatMessage(role: .assistant, text: text); assistantID = message.id; messages.append(message) }
                case "error":
                    if let reason = delta["reason"] as? String { reportFailure("Pi response failed (\(reason)).") }
                default: break
                }
            }
        case "message_end":
            if let message = event["message"] as? [String: Any], let reason = message["stopReason"] as? String, reason == "error", let error = message["errorMessage"] as? String { reportFailure(error) }
        case "tool_execution_start":
            assistantID = nil
            let name = event["toolName"] as? String ?? "board tool"
            setActivity("Using \(name)…", record: true)
        case "tool_execution_update":
            let name = event["toolName"] as? String ?? "board tool"
            let progress = textContent(event["partialResult"], limit: 240)
            activityText = progress.isEmpty ? "Using \(name)…" : "Using \(name)… \(progress)"
        case "tool_execution_end":
            let name = event["toolName"] as? String ?? "board tool"
            if event["isError"] as? Bool == true {
                let detail = textContent(event["result"], limit: 1200)
                reportFailure(detail.isEmpty ? "\(name) failed. Pi may provide more details." : "\(name) failed. \(detail)")
            } else if phase == .running { activityText = "Thinking…" }
        case "extension_error":
            reportFailure(event["error"] as? String ?? "Pi extension error.")
        case "auto_retry_start":
            setActivity("Retrying with Pi…", record: true)
        case "auto_retry_end":
            if phase == .running { setActivity("Thinking…", record: true) }
        case "agent_end": if phase == .running { phase = .ready; activityText = ""; assistantID = nil }
        default: break
        }
    }
    private func setActivity(_ text: String, record: Bool = false) {
        activityText = text
        if record && (messages.last?.role != .activity || messages.last?.text != text) {
            messages.append(ChatMessage(role: .activity, text: text))
        }
    }
    private func reportFailure(_ text: String) {
        activityText = "Pi reported an error"
        messages.append(ChatMessage(role: .error, text: text))
    }
    private func textContent(_ value: Any?, limit: Int) -> String {
        guard let object = value as? [String: Any], let parts = object["content"] as? [[String: Any]] else { return "" }
        let text = parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
    private func terminated(runID: UUID, status: Int32) {
        guard generation == runID else { return }
        fail("Pi stopped unexpectedly (exit \(status)). Check its executable and model configuration.")
    }
}
