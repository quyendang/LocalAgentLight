import CoreBluetooth
import Foundation

final class BluetoothLight: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceID = CBUUID(string: "E7BAA2E6-97AD-E697-A0E7-BABF73657276")
    private let writeID = CBUUID(string: "E7BAA2E6-97AD-E697-A0E7-BABF72786372")
    private let notifyID = CBUUID(string: "E7BAA2E6-97AD-E697-A0E7-BABF74786372")
    private let deviceID: UUID?
    var silent: Bool
    var onLink: ((Bool, String) -> Void)?
    var onAcknowledgment: ((LightState) -> Void)?
    var onDiscovery: ((UUID, String) -> Void)?
    private var manager: CBCentralManager!
    private var device: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var buffer: [UInt8] = []
    private var lastNotification: TimeInterval = 0
    private var reportedDevices: Set<UUID> = []
    private var lacksRequiredService = false
    private var deadline: TimeInterval = 0
    private var reconnectAfter: TimeInterval = 0
    private var sequence = UInt16.random(in: .min ... .max)
    private var desired: LightState = .idle
    private var cue = false
    private var inFlightState: LightState?
    private var applied: LightState?
    private var tone: Tone?
    private var phase: Phase = .scanning
    private var pending: Request?
    private var writeOffset = 0
    private var writeInProgress = false
    private var response: Frame?

    private enum Phase { case scanning, connecting, discovering, subscribing, ready, closing }
    private struct Request {
        let frame: Frame
        let bytes: [UInt8]
        var retries = 0
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var foundDevices: Bool { !reportedDevices.isEmpty }

    init(deviceID: UUID?, silent: Bool) {
        self.deviceID = deviceID
        self.silent = silent
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func update(_ state: LightState, cue: Bool = true) {
        desired = state
        self.cue = cue
        sendSceneIfNeeded()
    }

    func tick() {
        if phase == .scanning {
            if !lacksRequiredService, manager.state == .poweredOn, !manager.isScanning, now >= reconnectAfter {
                // Some lamps omit the service UUID from their advertisement.
                manager.scanForPeripherals(withServices: nil, options: nil)
            }
            return
        }
        guard phase != .closing, deadline > 0, now >= deadline else { return }
        if var request = pending, !writeInProgress, request.retries < 2 {
            request.retries += 1
            pending = request
            writeOffset = 0
            response = nil
            buffer.removeAll()
            writeNextChunk()
        } else {
            disconnect("Hết thời gian chờ thiết bị.")
        }
    }

    func stop() {
        if manager.state == .poweredOn {
            manager.stopScan()
            if let device { manager.cancelPeripheralConnection(device) }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: tick()
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            clearConnection()
            notifyLink(false, "Kiểm tra Bluetooth và quyền truy cập của ứng dụng.")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning else { return }
        guard let deviceID else {
            let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            let isPromLight = name?.caseInsensitiveCompare("PromLight") == .orderedSame
            let isACLight = name?.uppercased().hasPrefix("ACLIGHT-") == true
            let advertisesV04 = advertised.contains(serviceID)
            guard isPromLight || isACLight || advertisesV04,
                  reportedDevices.insert(peripheral.identifier).inserted else { return }
            let model = isPromLight ? "PromLight" : "AgentCore-Light"
            let compatibility: String
            if advertisesV04 {
                compatibility = "có quảng bá service V0.4"
            } else if isPromLight {
                compatibility = "thử chế độ Bluetooth HID với run --promlight"
            } else {
                compatibility = "chưa xác nhận khả năng tương thích V0.4"
            }
            print("\(model)  \(peripheral.identifier.uuidString)  —  \(compatibility)")
            if !isPromLight || advertisesV04 { onDiscovery?(peripheral.identifier, model) }
            return
        }
        guard peripheral.identifier == deviceID else { return }
        central.stopScan()
        phase = .connecting
        deadline = now + 10
        device = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === device, phase == .connecting else { return }
        phase = .discovering
        deadline = now + 5
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral === device {
            clearConnection()
            if !lacksRequiredService { notifyLink(false, "Đang chờ kết nối lại qua Bluetooth.") }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === device {
            clearConnection()
            if !lacksRequiredService { notifyLink(false, "Đang chờ kết nối lại qua Bluetooth.") }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === device, phase == .discovering else { return }
        guard error == nil else {
            disconnect("Không đọc được danh sách dịch vụ Bluetooth.")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            lacksRequiredService = true
            disconnect("Thiết bị không cung cấp service BLE V0.4. Ctrl+C để thoát.")
            return
        }
        peripheral.discoverCharacteristics([writeID, notifyID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === device, phase == .discovering else { return }
        guard error == nil,
              let write = service.characteristics?.first(where: { $0.uuid == writeID && $0.properties.contains(.write) }),
              let notify = service.characteristics?.first(where: { $0.uuid == notifyID && $0.properties.contains(.notify) }) else {
            disconnect("Thiết bị thiếu kênh ghi hoặc kênh thông báo BLE.")
            return
        }
        writeCharacteristic = write
        phase = .subscribing
        deadline = now + 5
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === device, characteristic.uuid == notifyID, phase != .closing else { return }
        if error != nil || !characteristic.isNotifying { disconnect("Không đăng ký được thông báo BLE.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === device, characteristic.uuid == notifyID, phase == .subscribing || phase == .ready,
              error == nil, let value = characteristic.value, value.count <= 512 else { return }
        if now - lastNotification > 0.5 { buffer.removeAll() }
        lastNotification = now
        buffer.append(contentsOf: value)
        while let frame = Frame.take(from: &buffer) { handle(frame) }
    }

    private func handle(_ frame: Frame) {
        if phase == .subscribing, pending == nil, frame.command == 0xE0,
           frame.payload.count == 6, frame.payload[0] == 4 {
            request(0x02)
            return
        }
        guard let pending, frame.sequence == pending.frame.sequence,
              frame.command == pending.frame.command | 0x80,
              writeOffset == pending.bytes.count else { return }
        response = frame
        if !writeInProgress { finishRequest() }
    }

    private func request(_ command: UInt8, payload: [UInt8] = []) {
        sequence &+= 1
        let frame = Frame(sequence: sequence, command: command, payload: payload)
        pending = Request(frame: frame, bytes: frame.bytes)
        writeOffset = 0
        response = nil
        writeNextChunk()
    }

    private func writeNextChunk() {
        guard let device, let writeCharacteristic, let pending else { return }
        let maximum = device.maximumWriteValueLength(for: .withResponse)
        guard maximum > 0 else {
            disconnect("Kích thước ghi BLE không hợp lệ.")
            return
        }
        let end = min(writeOffset + maximum, pending.bytes.count)
        let chunk = Data(pending.bytes[writeOffset..<end])
        writeOffset = end
        writeInProgress = true
        deadline = now + 2
        device.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === device, characteristic.uuid == writeID, writeInProgress,
              let pending, phase != .closing else { return }
        writeInProgress = false
        guard error == nil else {
            disconnect("Lỗi ghi BLE.")
            return
        }
        if writeOffset < pending.bytes.count {
            writeNextChunk()
        } else if response != nil {
            finishRequest()
        } else {
            deadline = now + 0.5
        }
    }

    private func finishRequest() {
        guard let response, let pending else { return }
        self.pending = nil
        self.response = nil
        deadline = 0
        let data = response.payload
        switch pending.frame.command {
        case 0x02:
            guard data.count == 16, data[0] == 0, data[1] <= 4, data[2] >= 4,
                  data[8] == 0, data[9] == 1 else {
                disconnect("Thiết bị không xác nhận giao thức AgentCore-Light V0.4.")
                return
            }
            request(0x04)
        case 0x04:
            guard data.count == 23, data[0] == 0, data[1] == 1, data[6] == 3,
                  data[5] & 0x05 == 0x05, data[8] & 1 == 1 else {
                disconnect("Thiết bị không hỗ trợ cảnh đèn V0.4.")
                return
            }
            let minimum = UInt16(data[16]) << 8 | UInt16(data[17])
            let maximum = UInt16(data[18]) << 8 | UInt16(data[19])
            if data[5] & 2 == 2, data[15] > 0, maximum > 0, minimum <= maximum, data[20] > 0 {
                tone = Tone(frequency: min(max(2_000, minimum), maximum), volume: min(25, data[20]))
            }
            phase = .ready
            notifyLink(true, "Đã xác nhận thiết bị BLE V0.4.")
            sendSceneIfNeeded()
        case 0x20:
            let digest = pending.frame.payload.reduce(UInt16(0)) { $0 + UInt16($1) }
            if response.acceptsScene(digest: digest), let state = inFlightState {
                onAcknowledgment?(state)
            } else {
                notifyLink(true, "Thiết bị không xác nhận cảnh đèn.")
            }
            // A rejected scene is tried again on the next state change or reconnect.
            applied = inFlightState
            sendSceneIfNeeded()
        default:
            break
        }
    }

    private func sendSceneIfNeeded() {
        guard phase == .ready, pending == nil, applied != desired else { return }
        inFlightState = desired
        request(0x20, payload: desired.scene(tone: cue && !silent ? tone : nil))
    }

    private func disconnect(_ reason: String) {
        notifyLink(false, reason)
        if let device {
            phase = .closing
            manager.cancelPeripheralConnection(device)
        } else {
            clearConnection()
        }
    }

    private func notifyLink(_ connected: Bool, _ message: String) {
        print(message)
        onLink?(connected, message)
    }

    private func clearConnection() {
        device = nil
        writeCharacteristic = nil
        pending = nil
        response = nil
        writeInProgress = false
        applied = nil
        tone = nil
        buffer.removeAll()
        deadline = 0
        reconnectAfter = now + 3
        phase = .scanning
    }
}
