import AppKit
import Combine
import SwiftUI

@MainActor
final class DesktopModel: ObservableObject {
    @Published private(set) var state: LightState = .idle
    @Published private(set) var source = "Chưa có sự kiện"
    @Published private(set) var connected = false
    @Published private(set) var connectionMessage = "Đang chờ PromLight"
    @Published private(set) var confirmation = ""
    @Published private(set) var switching = false
    @Published private(set) var running = false
    @Published private(set) var mode: LightMode = .promLight
    @Published private(set) var devices: [UUID] = []
    @Published private(set) var scanning = false
    @Published var silent = UserDefaults.standard.bool(forKey: "desktopSilent") {
        didSet {
            UserDefaults.standard.set(silent, forKey: "desktopSilent")
            session?.silent = silent
        }
    }

    private var session: LightSession?
    private var scanner: BluetoothLight?
    private var stopScan: DispatchWorkItem?
    private var dropping = false
    private var afterStop: [() -> Void] = []

    func start() {
        if let savedID = UserDefaults.standard.string(forKey: "desktopBLEDevice"),
           let id = UUID(uuidString: savedID) {
            begin(.ble(id))
        } else {
            begin(.promLight)
        }
    }

    func begin(_ mode: LightMode) {
        guard !switching, !dropping else { return }
        switching = true
        finishScan()
        let oldSession = session
        if let oldSession {
            oldSession.shutdown { [weak self] in self?.replaceSession(mode) }
        } else {
            replaceSession(mode)
        }
    }

    private func replaceSession(_ mode: LightMode) {
        session = nil
        switching = false
        if dropping {
            let callbacks = afterStop
            afterStop.removeAll()
            callbacks.forEach { $0() }
            return
        }
        self.mode = mode
        connected = false
        running = false
        confirmation = ""
        state = .idle
        source = "Chưa có sự kiện"
        connectionMessage = "Đang chờ kết nối Bluetooth."
        do {
            let handle = try LightSession(mode: mode, silent: silent)
            handle.onLink = { [weak self] connected, message in
                self?.connected = connected
                self?.connectionMessage = message
            }
            handle.onState = { [weak self] state, agent in
                self?.state = state
                switch agent {
                case .claude?: self?.source = "Claude Code"
                case .codex?: self?.source = "Codex"
                case nil: self?.source = "Thử thủ công"
                }
                self?.confirmation = ""
            }
            handle.onAcknowledgment = { [weak self] state in
                guard self?.state == state else { return }
                self?.confirmation = "Đèn đã xác nhận"
            }
            session = handle
            running = true
            switch mode {
            case .promLight:
                UserDefaults.standard.removeObject(forKey: "desktopBLEDevice")
                connectionMessage = "Bật đèn và kết nối PromLight trong Bluetooth của macOS."
            case .ble(let id):
                UserDefaults.standard.set(id.uuidString, forKey: "desktopBLEDevice")
                connectionMessage = "Đang tìm đèn AgentCore-Light đã chọn."
            case .preview:
                connectionMessage = "Đang mô phỏng trên màn hình."
            }
        } catch let error as IPCError {
            if error == .alreadyRunning {
                connectionMessage = "Một phiên LocalAgentLight đang chạy. Hãy thoát phiên đó rồi bấm Thử lại."
            } else {
                connectionMessage = error.rawValue
            }
        } catch {
            connectionMessage = "Không thể bắt đầu nhận trạng thái cục bộ."
        }
    }

    func preview(_ state: LightState) { session?.test(state) }

    func retry() { begin(mode) }

    func scan() {
        finishScan()
        devices.removeAll()
        scanning = true
        let scanner = BluetoothLight(deviceID: nil, silent: true)
        scanner.onDiscovery = { [weak self] id, _ in
            self?.devices.append(id)
        }
        self.scanner = scanner
        let stop = DispatchWorkItem { [weak self] in self?.finishScan() }
        stopScan = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: stop)
    }

    func finishScan() {
        stopScan?.cancel()
        stopScan = nil
        scanner?.stop()
        scanner = nil
        scanning = false
    }

    func shutdown(_ finish: @escaping () -> Void) {
        guard !dropping else { return }
        dropping = true
        finishScan()
        if switching {
            afterStop.append(finish)
        } else if let session {
            session.shutdown(finish)
        } else {
            finish()
        }
    }
}

@MainActor
final class DesktopDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = DesktopModel()
    private var window: NSWindow?
    private var requestedTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "Thoát LocalAgentLight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = menu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 844, height: 654),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalAgentLight"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: DesktopView(model: model))
        window.contentMinSize = NSSize(width: 790, height: 570)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !requestedTermination else { return .terminateLater }
        requestedTermination = true
        DispatchQueue.main.async {
            self.model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

@MainActor
func runDesktopApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = DesktopDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
