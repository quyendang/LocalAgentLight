import AudioToolbox
import Foundation
import IOKit.hid

// PromLight's vendor HID reports use a two-byte marker and an XOR checksum.
enum PromLightReport {
    static let brightness: UInt8 = 0x02
    static let light: UInt8 = 0x04

    static func encode(_ command: UInt8, _ data: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x5E, 0x5E, UInt8(data.count + 2), command]
        bytes += data
        bytes.append(bytes.reduce(0, ^))
        return bytes + Array(repeating: 0, count: 64 - bytes.count)
    }

    static func decode(_ report: [UInt8]) -> (code: UInt8, data: [UInt8])? {
        let start = report.first == 2 ? 1 : 0
        guard report.count >= start + 5, report[start] == 0x5E, report[start + 1] == 0x5E else { return nil }
        let count = Int(report[start + 2])
        let end = start + 3 + count
        guard (2...61).contains(count), end <= report.count, report[start..<end].reduce(0, ^) == 0 else { return nil }
        return (report[start + 3], Array(report[(start + 4)..<(end - 1)]))
    }

    static func payload(for state: LightState) -> [UInt8] {
        switch state {
        case .idle: [0xFF, 0]
        case .working: [2, 1, 1, 0xFF]
        case .waiting: [2, 2, 1, 0xFF, 3, 10]
        case .success: [1, 1, 1, 0xFF]
        case .error: [4, 2, 1, 0xFF, 3, 6]
        }
    }
}

final class PromLight {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    var silent: Bool
    var onLink: ((Bool, String) -> Void)?
    var onAcknowledgment: ((LightState) -> Void)?
    private var target: IOHIDDevice?
    private var ready = false
    private var nextSearch: TimeInterval = 0
    private var desired: LightState?
    private var sent: LightState?
    private var cue = false
    private var pending: (command: UInt8, state: LightState?, cue: Bool, deadline: TimeInterval)?
    private var multiple = false
    private var stopping = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init?(silent: Bool) {
        self.silent = silent
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x07D7,
            kIOHIDProductIDKey: 0x6B01,
            kIOHIDDeviceUsagePageKey: 0xFF00,
            kIOHIDDeviceUsageKey: 1,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
            print("Không mở được kênh Bluetooth HID của macOS.")
            return nil
        }
    }

    deinit {
        disconnect()
        IOHIDManagerClose(manager, 0)
        input.deallocate()
    }

    func tick() {
        if let pending, now >= pending.deadline {
            notifyLink(false, "PromLight không xác nhận lệnh. Đang kết nối lại.")
            disconnect()
        }
        guard !stopping, now >= nextSearch else { return }
        nextSearch = now + 2
        let matches = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        if let target {
            if !matches.contains(target) {
                disconnect()
                notifyLink(false, "Đang chờ PromLight kết nối lại.")
            }
        } else {
            attach(from: matches)
        }
    }

    func update(_ state: LightState, cue: Bool = true) {
        desired = state
        self.cue = cue
        sendState()
    }

    func shutDown() {
        stopping = true
        if desired != nil { update(.idle, cue: false) }
    }

    private func attach(from matches: Set<IOHIDDevice>) {
        let candidates = matches.filter {
            (IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) == "Bluetooth Low Energy"
        }
        if candidates.count > 1 {
            if !multiple { notifyLink(false, "Có nhiều đèn PromLight. Hãy kết nối một đèn.") }
            multiple = true
            return
        }
        multiple = false
        guard let device = candidates.first else { return }
        guard IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else {
            notifyLink(false, "Không mở được PromLight. Kiểm tra cài đặt Bluetooth.")
            return
        }
        target = device
        IOHIDDeviceRegisterInputReportCallback(device, input, 256, { context, result, _, _, _, report, count in
            guard result == kIOReturnSuccess, let context, (5...256).contains(count) else { return }
            let instance = Unmanaged<PromLight>.fromOpaque(context).takeUnretainedValue()
            instance.receive(Array(UnsafeBufferPointer(start: report, count: count)))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        send(PromLightReport.brightness, [1], state: nil, cue: false)
    }

    private func send(_ command: UInt8, _ data: [UInt8], state: LightState?, cue: Bool) {
        guard let target else { return }
        let report = PromLightReport.encode(command, data)
        pending = (command, state, cue, now + 1.5)
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(target, kIOHIDReportTypeOutput, 2, $0.baseAddress!, $0.count)
        }
        if result != kIOReturnSuccess {
            notifyLink(false, "macOS báo lỗi gửi lệnh PromLight (\(result)).")
            disconnect()
        }
    }

    private func receive(_ data: [UInt8]) {
        guard let pending, let frame = PromLightReport.decode(data),
              frame.code & 0x3F == pending.command else { return }
        if frame.code == (pending.command | 0x40) {
            notifyLink(ready, "PromLight từ chối lệnh HID.")
            if pending.state == nil { disconnect(); return }
        } else {
            guard frame.code == (pending.command | 0x80) else { return }
            if let state = pending.state {
                print("PromLight xác nhận \(state).")
                onAcknowledgment?(state)
                if !silent, pending.cue, state == .waiting || state == .success || state == .error {
                    AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)
                }
            } else {
                guard frame.data.count >= 2, frame.data[0] == 1 else { return }
                ready = true
                notifyLink(true, "Đã xác nhận PromLight qua Bluetooth HID.")
            }
        }
        sent = pending.state
        self.pending = nil
        sendState()
    }

    private func sendState() {
        guard ready, pending == nil, let desired, sent != desired else { return }
        send(PromLightReport.light, PromLightReport.payload(for: desired), state: desired, cue: cue)
    }

    private func notifyLink(_ connected: Bool, _ message: String) {
        print(message)
        onLink?(connected, message)
    }

    func disconnect() {
        if let target {
            IOHIDDeviceUnscheduleFromRunLoop(target, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(target, 0)
        }
        target = nil
        ready = false
        sent = nil
        pending = nil
        nextSearch = now + 2
    }
}
