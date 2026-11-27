import Foundation

enum LightState: UInt8, CaseIterable, CustomStringConvertible {
    case idle, working, waiting, success, error

    var description: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .waiting: "waiting"
        case .success: "success"
        case .error: "error"
        }
    }

    func scene(tone: Tone?) -> [UInt8] {
        var bytes: [UInt8] = [1, 1, 0, 0, 0, 0]
        bytes += Array(repeating: 0, count: 53)
        switch self {
        case .idle: break
        case .working: bytes.replaceSubrange(26...29, with: [60, 145, 255, 40])
        case .waiting: bytes.replaceSubrange(26...29, with: [255, 170, 0, 45])
        case .success: bytes.replaceSubrange(42...45, with: [0, 220, 80, 45])
        case .error: bytes.replaceSubrange(10...13, with: [255, 0, 0, 50])
        }
        if let tone, self == .waiting || self == .success || self == .error {
            bytes[57] = 1 // One sequence, then silence.
            bytes[58] = 1
            bytes += [
                UInt8(tone.frequency >> 8), UInt8(truncatingIfNeeded: tone.frequency),
                0, self == .error ? 200 : 100, tone.volume,
            ]
        }
        return bytes
    }
}

struct Tone {
    let frequency: UInt16
    let volume: UInt8
}

struct Frame {
    let sequence: UInt16
    let command: UInt8
    let payload: [UInt8]

    var bytes: [UInt8] {
        var data: [UInt8] = [
            0x55, 0xAA, 4, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
            command, 0, UInt8(payload.count),
        ]
        data += payload
        data.append(data.reduce(0, &+))
        return data
    }

    static func take(from buffer: inout [UInt8]) -> Frame? {
        while buffer.count >= 2 {
            guard buffer[0] == 0x55, buffer[1] == 0xAA else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= 8 else { return nil }
            let length = Int(buffer[6]) * 256 + Int(buffer[7])
            guard buffer[2] == 4, length <= 235 else {
                buffer.removeFirst()
                continue
            }
            let end = 8 + length
            guard buffer.count > end else { return nil }
            guard buffer[end] == buffer[..<end].reduce(0, &+) else {
                buffer.removeFirst()
                continue
            }
            let frame = Frame(
                sequence: UInt16(buffer[3]) << 8 | UInt16(buffer[4]),
                command: buffer[5],
                payload: Array(buffer[8..<end])
            )
            buffer.removeFirst(end + 1)
            return frame
        }
        return nil
    }

    func acceptsScene(digest: UInt16) -> Bool {
        let fields = payload.count == 4 && payload.first == 0 ? Array(payload.dropFirst()) : payload
        return fields.count == 3 && fields[0] <= 1
            && (UInt16(fields[1]) << 8 | UInt16(fields[2])) == digest
    }
}
