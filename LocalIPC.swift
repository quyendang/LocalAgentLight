import Darwin
import Dispatch
import Foundation

enum Agent: UInt8 {
    case claude = 1, codex = 2

    init?(_ name: String) {
        switch name {
        case "claude": self = .claude
        case "codex": self = .codex
        default: return nil
        }
    }
}

struct LocalIPC {
    private let directory: String
    private var socketPath: String { directory + "/s" }

    init() throws {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &path, path.count)
        guard length > 1, length <= path.count else { throw IPCError.invalidPath }
        directory = String(decoding: path.prefix(length - 1).map(UInt8.init(bitPattern:)), as: UTF8.self)
            + "local-agent-light"
    }

    private func verifyDirectory() throws {
        var info = stat()
        guard lstat(directory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw IPCError.invalidPath
        }
    }

    private func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw IPCError.invalidPath }
        let length = MemoryLayout<sockaddr_un>.size - capacity + bytes.count + 1
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(length)) }
        }
    }

    func send(_ agent: Agent, _ state: LightState) {
        guard (try? verifyDirectory()) != nil else { return }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let message = [agent.rawValue, state.rawValue]
        _ = try? withAddress { address, length in
            message.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, MSG_DONTWAIT, address, length) }
        }
    }

    func listen(onClose: @escaping () -> Void, _ receive: @escaping (Agent, LightState) -> Void) throws -> DispatchSourceRead {
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST else { throw IPCError.invalidPath }
        try verifyDirectory()
        let lock = open(directory + "/lock", O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, 0o600)
        guard lock >= 0 else { throw IPCError.invalidPath }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw IPCError.alreadyRunning
        }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            close(lock)
            throw IPCError.cannotListen
        }
        do {
            guard unlink(socketPath) == 0 || errno == ENOENT,
                  try withAddress({ bind(fd, $0, $1) }) == 0,
                  chmod(socketPath, 0o600) == 0 else { throw IPCError.cannotListen }
        } catch {
            close(fd)
            close(lock)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            var message = [UInt8](repeating: 0, count: 3)
            // A bounded batch leaves time on the main queue for Bluetooth callbacks.
            for _ in 0..<64 {
                let size = message.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
                if size < 0 { break }
                if size == 2, let agent = Agent(rawValue: message[0]), let state = LightState(rawValue: message[1]) {
                    receive(agent, state)
                }
            }
        }
        source.setCancelHandler {
            unlink(socketPath)
            close(fd)
            close(lock)
            onClose()
        }
        source.resume()
        return source
    }
}

enum IPCError: String, Error {
    case invalidPath = "Thư mục IPC của macOS không hợp lệ hoặc không thuộc riêng tài khoản này."
    case alreadyRunning = "LocalAgentLight đang chạy trong tài khoản này."
    case cannotOpenHID = "Không mở được kênh Bluetooth HID của macOS."
    case cannotListen = "Không mở được socket Unix cục bộ."
}
