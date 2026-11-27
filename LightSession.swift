import Foundation

enum LightMode: Equatable {
    case promLight
    case ble(UUID)
    case preview
}

final class LightSession {
    private var activeAgent: Agent?
    private var reset: Timer?
    private var tick: Timer?
    private var ipc: DispatchSourceRead?
    private var bluetooth: BluetoothLight?
    private var promLight: PromLight?
    private var shuttingDown = false
    private var onStopped: (() -> Void)?
    private var lastState: LightState?
    var onState: ((LightState, Agent?) -> Void)?
    var onLink: ((Bool, String) -> Void)?
    var onAcknowledgment: ((LightState) -> Void)?

    var waitingTimeout: TimeInterval? {
        didSet {
            if !shuttingDown, lastState == .waiting { scheduleWaitingTimeout() }
        }
    }

    var silent: Bool {
        didSet {
            bluetooth?.silent = silent
            promLight?.silent = silent
        }
    }

    init(mode: LightMode, silent: Bool, waitingTimeout: TimeInterval? = nil) throws {
        self.silent = silent
        self.waitingTimeout = waitingTimeout
        ipc = try LocalIPC().listen(onClose: { [weak self] in
            let finish = self?.onStopped
            self?.onStopped = nil
            finish?()
        }) { [weak self] agent, state in
            self?.receive(state, from: agent)
        }

        switch mode {
        case .promLight:
            guard let device = PromLight(silent: silent) else {
                ipc?.cancel()
                throw IPCError.cannotOpenHID
            }
            device.onLink = { [weak self] in self?.onLink?($0, $1) }
            device.onAcknowledgment = { [weak self] in self?.onAcknowledgment?($0) }
            promLight = device
        case .ble(let id):
            let device = BluetoothLight(deviceID: id, silent: silent)
            device.onLink = { [weak self] in self?.onLink?($0, $1) }
            device.onAcknowledgment = { [weak self] in self?.onAcknowledgment?($0) }
            bluetooth = device
        case .preview:
            break
        }

        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.bluetooth?.tick()
            self?.promLight?.tick()
        }
    }

    deinit {
        ipc?.cancel()
        reset?.invalidate()
        tick?.invalidate()
    }

    func test(_ state: LightState) {
        guard !shuttingDown else { return }
        activeAgent = nil
        show(state, from: nil)
    }

    private func receive(_ state: LightState, from agent: Agent) {
        guard !shuttingDown else { return }
        if state == .idle, activeAgent != agent { return }
        if state == lastState, agent == activeAgent {
            if state == .waiting { scheduleWaitingTimeout() }
            return
        }
        activeAgent = state == .idle ? nil : agent
        show(state, from: agent)
    }

    private func show(_ state: LightState, from agent: Agent?, cue: Bool = true) {
        lastState = state
        onState?(state, agent)
        reset?.invalidate()
        bluetooth?.update(state, cue: cue)
        promLight?.update(state, cue: cue)
        if state == .waiting {
            scheduleWaitingTimeout()
        } else if state == .success || state == .error {
            reset = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                self?.show(.waiting, from: agent, cue: false)
            }
        }
    }

    private func scheduleWaitingTimeout() {
        reset?.invalidate()
        reset = waitingTimeout.map { interval in
            let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                guard let self else { return }
                let agent = self.activeAgent
                self.activeAgent = nil
                self.show(.idle, from: agent, cue: false)
            }
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    }

    func shutdown(_ finish: @escaping () -> Void) {
        guard !shuttingDown else { return }
        shuttingDown = true
        onStopped = finish
        reset?.invalidate()
        bluetooth?.update(.idle, cue: false)
        promLight?.shutDown()
        let grace = promLight != nil ? 2.0 : (bluetooth != nil ? 0.8 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [self] in
            bluetooth?.stop()
            promLight?.disconnect()
            tick?.invalidate()
            ipc?.cancel()
        }
    }
}
