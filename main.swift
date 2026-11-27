import Darwin
import Dispatch
import Foundation

func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func hookTemplate(_ agent: Agent) throws -> String {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
        throw IPCError.invalidPath
    }
    let name = agent == .claude ? "claude" : "codex"
    var events: [(String, LightState, String?)] = [
        ("UserPromptSubmit", .working, nil),
        ("PermissionRequest", .waiting, nil),
        ("PostToolUse", .working, nil),
        ("Stop", .success, nil),
        ("SessionEnd", .idle, nil),
    ]
    if agent == .claude {
        events += [
            ("PreToolUse", .waiting, "AskUserQuestion|ExitPlanMode"),
            ("PostToolUseFailure", .working, nil),
            ("Elicitation", .waiting, nil),
            ("ElicitationResult", .working, nil),
            ("StopFailure", .error, nil),
        ]
    }
    var hooks: [String: [[String: Any]]] = [:]
    for (event, state, matcher) in events {
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "exec \(shellQuote(executable)) hook \(name) \(state)",
                "timeout": 2,
            ] as [String: Any]],
        ]
        if let matcher { group["matcher"] = matcher }
        hooks[event, default: []].append(group)
    }
    let json = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
    return String(decoding: json, as: UTF8.self)
}

func runLight(deviceID: UUID?, silent: Bool, usePromLight: Bool = false) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let mode = usePromLight ? LightMode.promLight : deviceID.map(LightMode.ble) ?? .preview
    let session = try LightSession(mode: mode, silent: silent)
    session.onState = { state, _ in print(state) }
    if usePromLight {
        print("Đang chờ đèn PromLight đã kết nối trong Bluetooth của macOS.")
    } else {
        print(deviceID == nil ? "Chế độ mô phỏng. Đang chờ hook cục bộ." : "Đang chờ đèn BLE và hook cục bộ.")
    }
    for number in [SIGINT, SIGTERM] { signal(number, SIG_IGN) }
    let signals = [SIGINT, SIGTERM].map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { session.shutdown { exit(0) } }
        source.resume()
        return source
    }
    withExtendedLifetime((session, signals)) { RunLoop.main.run() }
}

func selfTest() {
    let scene = LightState.idle.scene(tone: nil)
    let off = Frame(sequence: 1, command: 0x20, payload: scene).bytes
    precondition(off == [0x55, 0xAA, 0x04, 0, 1, 0x20, 0, 0x3B, 1, 1]
        + Array(repeating: 0, count: 57) + [0x61])
    var buffer = [0, 0x55] + Array(off.prefix(12))
    precondition(Frame.take(from: &buffer) == nil)
    buffer += off.dropFirst(12)
    buffer += off
    precondition(Frame.take(from: &buffer)?.payload == scene)
    precondition(Frame.take(from: &buffer)?.sequence == 1 && buffer.isEmpty)
    var damaged = off
    damaged[damaged.count - 1] ^= 1
    damaged += off
    precondition(Frame.take(from: &damaged)?.payload == scene)
    let tone = Tone(frequency: 2000, volume: 25)
    precondition(LightState.success.scene(tone: tone).suffix(7) == [1, 1, 7, 208, 0, 100, 25])
    precondition(LightState.working.scene(tone: tone).count == 59)
    precondition(Frame(sequence: 2, command: 0xA0, payload: [1, 1, 0xE7]).acceptsScene(digest: 0x1E7))
    precondition(Frame(sequence: 2, command: 0xA0, payload: [0, 1, 1, 0xE7]).acceptsScene(digest: 0x1E7))
    precondition(!Frame(sequence: 2, command: 0xA0, payload: [9, 1, 1, 0xE7]).acceptsScene(digest: 0x1E7))
    let read = PromLightReport.encode(0x02, [1])
    precondition(read.count == 64 && read.prefix(6) == [0x5E, 0x5E, 3, 2, 1, 0])
    precondition(PromLightReport.decode([2, 0x5E, 0x5E, 4, 0x82, 1, 40, 0xAF])?.code == 0x82)
    precondition(PromLightReport.decode([0x5E, 0x5E, 4, 0x82, 1, 40, 0x00]) == nil)
    precondition(PromLightReport.payload(for: .idle) == [0xFF, 0])
    print("Kiểm tra khung BLE và PromLight HID đã qua.")
}

let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
if args.first == "hook" {
    // The configured command names the event. The hook payload on stdin is unused.
    if args.count == 3, let agent = Agent(args[1]),
       let state = LightState.allCases.first(where: { $0.description == args[2] }) {
        (try? LocalIPC())?.send(agent, state)
    }
    exit(0)
}

do {
    switch args {
    case []: MainActor.assumeIsolated { runDesktopApp() }
    case ["self-test"]: selfTest()
    case ["hooks", "claude"]: print(try hookTemplate(.claude))
    case ["hooks", "codex"]: print(try hookTemplate(.codex))
    case ["run", "--dry-run"]: try runLight(deviceID: nil, silent: true)
    case ["run", "--promlight"], ["run", "--promlight", "--silent"]:
        try runLight(deviceID: nil, silent: args.count == 3, usePromLight: true)
    case ["scan"]:
        setvbuf(stdout, nil, _IOLBF, 0)
        let bluetooth = BluetoothLight(deviceID: nil, silent: true)
        print("Đang tìm AgentCore-Light và PromLight qua BLE trong 12 giây…")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in bluetooth.tick() }
        RunLoop.main.run(until: Date().addingTimeInterval(12))
        timer.invalidate()
        bluetooth.stop()
        if !bluetooth.foundDevices { print("Không thấy AgentCore-Light hoặc PromLight đang quảng bá BLE.") }
    default:
        guard (args.count == 2 || (args.count == 3 && args[2] == "--silent")),
              args[0] == "run", let id = UUID(uuidString: args[1]) else {
            report("Cách dùng: LocalAgentLight scan | run UUID [--silent] | run --promlight [--silent] | run --dry-run | hooks claude|codex | self-test")
            exit(2)
        }
        try runLight(deviceID: id, silent: args.count == 3)
    }
} catch let error as IPCError {
    report(error.rawValue)
    exit(1)
} catch {
    report("Không thể thực hiện lệnh LocalAgentLight.")
    exit(1)
}
