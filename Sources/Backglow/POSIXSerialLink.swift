import BackglowCore
import Darwin
import Foundation

/// A blocking serial port for the firmware installer. The ROM loader's request and answer
/// pattern and the exact modem-line timing are simpler to get right here than through
/// ORSSerialPort's delegate callbacks. Opened exclusively; use from one thread only.
final class POSIXSerialLink: ESPSerialLink {
    private var descriptor: Int32

    // _IOR('t', 106, int), _IOW('t', 109, int), _IO('t', 13) from <sys/ttycom.h>.
    private static let getModemLines: UInt = 0x4004_746a
    private static let setModemLines: UInt = 0x8004_746d
    private static let exclusive: UInt = 0x2000_740d

    init(path: String, baudRate: Int = 115_200) throws {
        descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try check(ioctl(descriptor, Self.exclusive))
            var options = termios()
            try check(tcgetattr(descriptor, &options))
            cfmakeraw(&options)
            options.c_cflag |= tcflag_t(CLOCAL | CREAD)
            options.c_cflag &= ~tcflag_t(CRTSCTS)
            try check(cfsetspeed(&options, speed_t(baudRate)))
            try check(tcsetattr(descriptor, TCSANOW, &options))
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress! + offset, data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN {
                var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                guard poll(&poller, 1, 2_000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func read(timeout: TimeInterval) throws -> Data {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, Int32(max(timeout, 0) * 1000))
        guard ready > 0 else {
            if ready < 0, errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return Data()
        }
        guard poller.revents & Int16(POLLIN) != 0 else {
            // The adapter was unplugged.
            throw POSIXError(.ENXIO)
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0, errno != EAGAIN { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(buffer.prefix(max(count, 0)))
    }

    func setLines(dtr: Bool, rts: Bool) throws {
        var lines: Int32 = 0
        try check(ioctl(descriptor, Self.getModemLines, &lines))
        lines = dtr ? lines | TIOCM_DTR : lines & ~TIOCM_DTR
        lines = rts ? lines | TIOCM_RTS : lines & ~TIOCM_RTS
        try check(ioctl(descriptor, Self.setModemLines, &lines))
    }

    func discardInput() {
        tcflush(descriptor, TCIFLUSH)
    }

    func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func check(_ result: Int32) throws {
        guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
