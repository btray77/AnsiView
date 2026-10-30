import AnsiCore
import Darwin
import Foundation

// ansixfer: runs one AnsiCore file transfer engine over a real byte channel, for interoperability
// tests against lrzsz and C-Kermit and for throughput measurements. Not part of the app.

let usage = """
usage: ansixfer send <protocol> [options] <file>... <channel>
       ansixfer receive <protocol> [options] --dir <directory> <channel>
protocols: xmodem xmodem-crc xmodem-1k ymodem ymodem-g zmodem kermit
channels:  --exec "<command>"     child on a socket pair (its stdin and stdout)
           --pty "<command>"      child on a pseudo terminal in raw mode
           --connect host:port    TCP client
           --listen port          TCP server, one connection (127.0.0.1)
           --stdio                our own stdin and stdout
options:   --telnet               run over telnet (IAC handling, BINARY requested)
           --resume               ZMODEM: ask to resume (send) or resume a kept .part (receive)
           --keep-partial         keep the .part of an interrupted receive for a later resume
           --max-size N           refuse or stop files over N bytes
           --name NAME            file name for a plain XMODEM receive
           --padding keep|strip   plain XMODEM final block padding (default strip)
           --escctl               ZMODEM: escape all control characters
           --escape-telnet        ZMODEM: also escape 0xFF and CR
           --crc16                ZMODEM: do not use CRC-32
           --block N              ZMODEM subpacket size when sending (256 to 8192)
           --window N             ZMODEM receive window to advertise (0 streams)
           --check 1|2|3          Kermit block check type
           --packet N             Kermit longest packet (94 or more; more enables long packets)
           --kermit-window N      Kermit sliding window size (1 to 31)
           --eighth-bit           Kermit: ask for 8th bit prefixing
           --abort-after N        cancel once N file bytes have moved (to test resume)
           --kill-after N         stop dead (no cancel sent) once N file bytes have moved
           --quiet                no progress line
"""

func die(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

enum Channel {
    case exec(String), pty(String), connect(String, UInt16), listen(UInt16), stdio
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { die(usage) }
let direction: TransferDirection
switch arguments.removeFirst() {
case "send": direction = .send
case "receive", "recv": direction = .receive
case "--help", "-h": print(usage); exit(0)
default: die(usage)
}
guard let kind = TransferProtocolKind(rawValue: arguments.removeFirst()) else { die("unknown protocol\n" + usage) }

var options = TransferOptions()
var sinkOptions = DownloadsDirectorySink.Options()
var channel: Channel?
var directory: String?
var files: [String] = []
var useTelnet = false
var quiet = false
var xmodemName = "download.bin"
var abortAfter: Int?
var killAfter: Int?

func value(_ name: String) -> String {
    guard !arguments.isEmpty else { die("\(name) needs a value") }
    return arguments.removeFirst()
}

func intValue(_ name: String) -> Int {
    guard let number = Int(value(name)) else { die("\(name) needs a number") }
    return number
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--exec": channel = .exec(value(argument))
    case "--pty": channel = .pty(value(argument))
    case "--connect":
        let target = value(argument)
        guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) else { die("--connect host:port") }
        channel = .connect(String(target[..<colon]), port)
    case "--listen":
        guard let port = UInt16(value(argument)) else { die("--listen port") }
        channel = .listen(port)
    case "--stdio": channel = .stdio
    case "--dir": directory = value(argument)
    case "--telnet": useTelnet = true
    case "--resume": options.resume = true
    case "--keep-partial": sinkOptions.keepPartialForResume = true
    case "--max-size": sinkOptions.maxFileSize = intValue(argument)
    case "--name": xmodemName = value(argument)
    case "--padding": options.xmodemPadding = value(argument) == "keep" ? .keep : .stripTrailingSUB
    case "--escctl": options.zmodemEscapeControl = true
    case "--escape-telnet": options.zmodemEscapeTelnet = true
    case "--crc16": options.zmodemUseCRC32 = false
    case "--block": options.zmodemBlockSize = intValue(argument)
    case "--window": options.zmodemReceiveWindow = intValue(argument)
    case "--check": options.kermitCheckType = intValue(argument)
    case "--packet": options.kermitMaxPacket = intValue(argument)
    case "--kermit-window": options.kermitWindow = intValue(argument)
    case "--eighth-bit": options.kermitForceEighthBitPrefix = true
    case "--abort-after": abortAfter = intValue(argument)
    case "--kill-after": killAfter = intValue(argument)
    case "--quiet", "-q": quiet = true
    default:
        if argument.hasPrefix("--") { die("unknown option \(argument)\n" + usage) }
        files.append(argument)
    }
}
guard let channel else { die("no channel given\n" + usage) }

// MARK: Channels

func makeArgv(_ command: String) -> [UnsafeMutablePointer<CChar>?] {
    let words: [String] = ["/bin/sh", "-c", command]
    return words.map { word -> UnsafeMutablePointer<CChar>? in strdup(word) } + [nil]
}

func spawn(_ command: String, stdinOut fd: Int32, closeInChild: [Int32], newSession: Bool) -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, fd, 0)
    posix_spawn_file_actions_adddup2(&actions, fd, 1)
    for other in closeInChild { posix_spawn_file_actions_addclose(&actions, other) }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    if newSession { posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) }
    var pid: pid_t = 0
    let argv = makeArgv(command)
    let result = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ)
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attributes)
    guard result == 0 else { die("cannot start \(command): \(String(cString: strerror(result)))", 1) }
    return pid
}

var childPid: pid_t?

func openChannel(_ channel: Channel) -> Int32 {
    switch channel {
    case .stdio:
        return -1
    case .exec(let command):
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { die("socketpair failed", 1) }
        childPid = spawn(command, stdinOut: pair[1], closeInChild: [pair[0], pair[1]], newSession: false)
        close(pair[1])
        return pair[0]
    case .pty(let command):
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else { die("no pty", 1) }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { die("cannot open \(String(cString: name))", 1) }
        var raw = termios()
        tcgetattr(slave, &raw)
        cfmakeraw(&raw)
        tcsetattr(slave, TCSANOW, &raw)
        var masterRaw = termios()
        tcgetattr(master, &masterRaw)
        cfmakeraw(&masterRaw)
        tcsetattr(master, TCSANOW, &masterRaw)
        childPid = spawn(command, stdinOut: slave, closeInChild: [master, slave], newSession: true)
        close(slave)
        return master
    case .connect(let host, let port):
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { die("cannot resolve \(host)", 1) }
        defer { freeaddrinfo(info) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0, connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            die("cannot connect to \(host):\(port): \(String(cString: strerror(errno)))", 1)
        }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    case .listen(let port):
        let server = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(server, 1) == 0 else { die("cannot listen on \(port): \(String(cString: strerror(errno)))", 1) }
        note("listening on 127.0.0.1:\(port)")
        let fd = accept(server, nil, nil)
        close(server)
        guard fd >= 0 else { die("accept failed", 1) }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}

// MARK: Session

let clock = SystemTransferClock()
let session: FileTransferSession
switch direction {
case .send:
    guard !files.isEmpty else { die("nothing to send") }
    let outgoing = files.map { path -> OutgoingFile in
        do { return try OutgoingFile(url: URL(fileURLWithPath: path)) } catch { die("cannot read \(path): \(error)", 1) }
    }
    session = FileTransferSession(sending: outgoing, kind: kind, options: options, clock: clock)
case .receive:
    guard let directory else { die("receive needs --dir") }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    session = FileTransferSession(receivingInto: DownloadsDirectorySink(directory: url, options: sinkOptions), kind: kind,
                                  options: options, clock: clock, xmodemFileName: xmodemName)
}

var interrupted: sig_atomic_t = 0
signal(SIGPIPE, SIG_IGN)
signal(SIGINT) { _ in interrupted = 1 }
signal(SIGTERM) { _ in interrupted = 1 }

let fd = openChannel(channel)
let readFD: Int32 = fd >= 0 ? fd : 0
let writeFD: Int32 = fd >= 0 ? fd : 1
if fd < 0, isatty(0) != 0 {
    var raw = termios()
    tcgetattr(0, &raw)
    cfmakeraw(&raw)
    tcsetattr(0, TCSANOW, &raw)
}
_ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
if writeFD != readFD { _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK) }

var telnet: TelnetTransferChannel?
var pending: [UInt8] = []
if useTelnet {
    var channel = TelnetTransferChannel()
    pending += channel.start()
    telnet = channel
}

session.onEvent = { event in
    if !quiet || event.isProblem {
        note("[\(kind.rawValue) \(direction.rawValue)] " + FileTransferSession.describe(event))
    }
}
var lastProgressLine = 0.0
session.onProgress = { p in
    guard !quiet, clock.now - lastProgressLine >= 1 else { return }
    lastProgressLine = clock.now
    let size = p.fileSize.map { "/\($0)" } ?? ""
    note(String(format: "[progress] %@ %d%@ bytes, %.0f B/s", p.fileName ?? "-", p.fileBytes, size, p.bytesPerSecond))
}

extension TransferEvent {
    var isProblem: Bool {
        switch self {
        case .failed, .cancelled, .fileSkipped: return true
        default: return false
        }
    }
}

session.start()
var buffer = [UInt8](repeating: 0, count: 65536)
var eof = false
var finishedAt: Double?
var killed = false
let started = clock.now

loop: while true {
    if interrupted != 0 {
        interrupted = 0
        session.cancel(reason: "interrupted")
    }
    if let limit = abortAfter, !session.isFinished, session.engine.progress.sessionBytes >= limit {
        abortAfter = nil
        session.cancel(reason: "test abort after \(limit) bytes")
    }
    if let limit = killAfter, session.engine.progress.sessionBytes >= limit {
        note("[test] stopping dead after \(session.engine.progress.sessionBytes) bytes")
        killed = true
        break loop
    }
    if pending.count < 65536 {
        let out = session.takeOutput(max: 65536)
        if !out.isEmpty { pending += telnet?.encode(out) ?? out }
    }
    var fds = [pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)]
    if !pending.isEmpty {
        if writeFD == readFD { fds[0].events |= Int16(POLLOUT) } else { fds.append(pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)) }
    }
    let ready = poll(&fds, nfds_t(fds.count), 20)
    if ready > 0 {
        if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0, !eof {
            let n = read(readFD, &buffer, buffer.count)
            if n > 0 {
                var bytes = Array(buffer[0..<n])
                if telnet != nil {
                    let decoded = telnet!.decode(bytes)
                    pending += decoded.reply
                    bytes = decoded.data
                }
                session.feed(bytes)
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                eof = true
            }
        }
        let writable = writeFD == readFD ? fds[0].revents & Int16(POLLOUT) != 0 : (fds.count > 1 && fds[1].revents & Int16(POLLOUT) != 0)
        if writable, !pending.isEmpty {
            let n = pending.withUnsafeBytes { write(writeFD, $0.baseAddress, $0.count) }
            if n > 0 { pending.removeFirst(n) } else if n < 0, errno != EAGAIN, errno != EINTR { pending.removeAll(); eof = true }
        }
    }
    session.tick()
    if eof, !session.isFinished {
        session.cancel(reason: "the other side closed the connection")
    }
    if session.isFinished {
        if finishedAt == nil { finishedAt = clock.now }
        // Linger briefly so the last bytes (final ACK, ZFIN, OO) reach the other side.
        if (pending.isEmpty && clock.now - finishedAt! > 0.3) || clock.now - finishedAt! > 5 || (eof && pending.isEmpty) { break }
    }
}

let elapsed = clock.now - started
if !killed, telnet == nil || true {
    // Nothing else to do; closing the channel lets a child see end of file.
}
if fd >= 0 { close(fd) }
var childStatus = "none"
if let pid = childPid {
    var status: Int32 = 0
    let deadline = clock.now + (killed ? 0 : 15)
    while waitpid(pid, &status, WNOHANG) == 0 {
        if clock.now > deadline {
            kill(pid, SIGTERM)
            usleep(200_000)
            _ = waitpid(pid, &status, WNOHANG)
            childStatus = "killed"
            break
        }
        usleep(20_000)
    }
    if childStatus != "killed" {
        childStatus = (status & 0x7F) == 0 ? "exit \((status >> 8) & 0xFF)" : "signal \(status & 0x7F)"
    }
}

let moved = session.engine.progress.sessionBytes
switch session.outcome {
case .completed(let done):
    print("result: completed")
    for file in done {
        print("file: \(file.name) bytes=\(file.bytes) sha256=\(file.sha256)" + (file.resumedFrom > 0 ? " resumed_from=\(file.resumedFrom)" : "")
              + (file.url.map { " saved=\($0.path)" } ?? ""))
    }
case .failed(let reason):
    print("result: failed: \(reason)")
case .cancelled(let reason):
    print("result: cancelled: \(reason)")
case nil:
    print("result: stopped")
}
print(String(format: "elapsed=%.3f s file_bytes=%d rate=%.0f B/s child=%@", elapsed, moved, elapsed > 0 ? Double(moved) / elapsed : 0, childStatus))
switch session.outcome {
case .completed: exit(0)
case .cancelled: exit(3)
default: exit(1)
}
