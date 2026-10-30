import Foundation

/// The ZFILE data subpacket: `name NUL size mtime mode serial filesleft bytesleft NUL`
/// (size decimal, mtime and mode octal).
public enum ZFileInfo {
    public struct Info: Equatable, Sendable {
        public var name: String
        public var size: Int?
        public var modified: Date?
        public var mode: Int?
    }

    public static func parse(_ data: [UInt8]) -> Info? {
        guard let nameEnd = data.firstIndex(of: 0), nameEnd > 0 else { return nil }
        var info = Info(name: TransferFileName.decode(Array(data[..<nameEnd])))
        let rest = data[(nameEnd + 1)...]
        let end = rest.firstIndex(of: 0) ?? rest.endIndex
        let fields = String(decoding: rest[rest.startIndex..<end], as: UTF8.self).split(separator: " ").map(String.init)
        if fields.count > 0, let size = Int(fields[0]), size >= 0 { info.size = size }
        if fields.count > 1, let mtime = Int(fields[1], radix: 8), mtime > 0 { info.modified = Date(timeIntervalSince1970: TimeInterval(mtime)) }
        if fields.count > 2, let mode = Int(fields[2], radix: 8), mode > 0 { info.mode = mode }
        return info
    }

    public static func encode(name: String, size: Int, modified: Date?, mode: Int?, filesLeft: Int, bytesLeft: Int) -> [UInt8] {
        let mtime = modified.map { max(0, Int($0.timeIntervalSince1970)) } ?? 0
        return Array(name.utf8) + [0]
            + Array("\(size) \(String(mtime, radix: 8)) \(String(mode ?? 0, radix: 8)) 0 \(filesLeft) \(bytesLeft)".utf8) + [0]
    }
}

/// Sends files with ZMODEM.
public final class ZModemSender: TransferEngine {
    let files: [OutgoingFile]

    private enum Phase { case waitRInit, waitSInitAck, waitFileResponse, streaming, waitDataAck, waitEOFResponse, waitFinAck }
    private var phase = Phase.waitRInit
    private let reader = ZReader()
    private var escaper = ZEscaper()
    private var crc32 = false
    private var receiverBuffer = 0
    private var fileIndex = 0
    private var position = 0
    private var bytesSinceAck = 0
    private var retries = 0
    private var rewindsWithoutProgress = 0
    private var furthestRewind = -1
    /// ZMODEM file positions are 32 bit.
    public static let maxFileSize = Int(UInt32.max)
    private var blockSize: Int
    private var fileAccepted = false
    private var fileSentAt: TimeInterval = 0

    public override var protocolName: String { "ZMODEM" }

    public init(files: [OutgoingFile], clock: TransferClock, options: TransferOptions = TransferOptions()) {
        self.files = files
        blockSize = min(8192, max(256, options.zmodemBlockSize))
        super.init(clock: clock, options: options)
        reader.expectsDataAfterHeaders = false
    }

    private var file: OutgoingFile { files[fileIndex] }

    override func begin() {
        send(Array("rz\r".utf8))
        send(ZFrame.hexHeader(ZHeader(type: ZType.rqinit)))
        arm(options.headerTimeout)
    }

    override func handle(_ bytes: [UInt8]) {
        var tokens: [ZToken] = []
        reader.feed(bytes) { tokens.append($0) }
        for token in tokens where status == .running {
            switch token {
            case .cancel:
                fail("cancelled by the receiver", cancelRemote: false)
            case .header(let header, _):
                handleHeader(header)
            case .badHeader, .badData, .data:
                break
            }
        }
    }

    private func sendHeader(_ header: ZHeader) {
        send(ZFrame.binaryHeader(header, crc32: crc32, escaper: escaper))
    }

    private func handleHeader(_ header: ZHeader) {
        switch header.type {
        case ZType.rinit:
            switch phase {
            case .waitRInit:
                retries = 0
                configure(header)
            case .waitFileResponse:
                // A ZRINIT right after our ZFILE is the receiver's answer to our ZRQINIT crossing
                // it; resending ZFILE then would make the receiver answer twice (two ZSKIPs skip
                // the next file too). Only a later ZRINIT means the ZFILE was lost.
                if clock.now - fileSentAt >= 2 { resend("receiver asked again (ZRINIT)") { self.sendFile() } }
            case .waitEOFResponse:
                fileDone()
            case .streaming, .waitDataAck:
                if position >= file.size { fileDone() }
            case .waitFinAck:
                resend("ZFIN not seen") { self.sendFin() }
            case .waitSInitAck:
                break
            }
        case ZType.ack:
            if phase == .waitSInitAck {
                retries = 0
                sendFile()
            } else if phase == .waitDataAck, header.position == position {
                retries = 0
                startData()
            }
        case ZType.rpos:
            guard [.waitFileResponse, .streaming, .waitDataAck, .waitEOFResponse].contains(phase) else { return }
            rewind(to: header.position)
        case ZType.skip:
            guard [.waitFileResponse, .streaming, .waitDataAck, .waitEOFResponse].contains(phase) else { return }
            emit(.fileSkipped(name: file.name, reason: "the receiver skipped it"))
            nextFile()
        case ZType.nak:
            switch phase {
            case .waitRInit: send(ZFrame.hexHeader(ZHeader(type: ZType.rqinit)))
            case .waitFileResponse: resend("ZNAK") { self.sendFile() }
            case .waitSInitAck: resend("ZNAK") { self.sendSInit() }
            case .waitFinAck: sendFin()
            default: break
            }
        case ZType.fin:
            if phase == .waitFinAck {
                send(Array("OO".utf8))
                complete()
            }
        case ZType.crc:
            if phase == .waitFileResponse {
                // The receiver asks for the file's CRC-32 (ZMCRC); answer and wait for its decision.
                var crc = CRC32.initial
                var offset = 0
                while offset < file.size, let chunk = try? file.read(offset: offset, count: 1 << 16), !chunk.isEmpty {
                    crc = CRC32.update(crc, chunk)
                    offset += chunk.count
                }
                send(ZFrame.hexHeader(ZHeader(type: ZType.crc, position: Int(CRC32.finish(crc)))))
                arm(options.headerTimeout)
            }
        case ZType.challenge:
            send(ZFrame.hexHeader(ZHeader(type: ZType.ack, bytes: header.bytes)))
        case ZType.ferr, ZType.abort, ZType.can:
            fail("the receiver stopped (\(ZType.name(header.type)))", cancelRemote: false)
        default:
            break
        }
    }

    private func configure(_ rinit: ZHeader) {
        let flags = rinit.f0
        receiverBuffer = Int(rinit.bytes[0]) | Int(rinit.bytes[1]) << 8
        crc32 = options.zmodemUseCRC32 && flags & ZCapability.canCRC32 != 0
        let escapeControl = options.zmodemEscapeControl || flags & ZCapability.escapeControl != 0
        escaper = ZEscaper(escapeControl: escapeControl, escapeTelnet: options.zmodemEscapeTelnet)
        emit(.negotiated(String(format: "ZRINIT flags 0x%02x, buffer %@, %@, %d byte subpackets%@%@", flags,
                                receiverBuffer == 0 ? "streaming" : "\(receiverBuffer)", crc32 ? "CRC-32" : "CRC-16", blockSize,
                                escapeControl ? ", control characters escaped" : "",
                                options.zmodemEscapeTelnet ? ", telnet escapes" : "")))
        if options.zmodemEscapeControl, flags & ZCapability.escapeControl == 0 {
            sendSInit()
        } else {
            sendFile()
        }
    }

    private func sendSInit() {
        // Tell the receiver we want control characters escaped (TESCCTL) too; empty attention string.
        sendHeader(ZHeader(type: ZType.sinit, f0: 0x40))
        send(ZFrame.subpacket([0], end: ZEnd.crcW, crc32: crc32, escaper: &escaper))
        phase = .waitSInitAck
        arm(options.headerTimeout)
    }

    private func sendFile() {
        guard fileIndex < files.count else {
            sendFin()
            return
        }
        if !fileAccepted, phase != .waitFileResponse {
            if file.size > Self.maxFileSize {
                // ZMODEM positions are 32 bits: a larger file would wrap silently.
                emit(.fileSkipped(name: file.name, reason: "ZMODEM cannot send files of 4 GiB or more"))
                fileIndex += 1
                sendFile()
                return
            }
            hashingFile = file
            progress.fileName = file.name
            progress.fileSize = file.size
            progress.fileBytes = 0
            furthestRewind = -1
            rewindsWithoutProgress = 0
            emit(.fileStarted(name: file.name, size: file.size, offset: 0))
        }
        let remaining = files[fileIndex...].reduce(0) { $0 + $1.size }
        let info = ZFileInfo.encode(name: file.name, size: file.size, modified: file.modified, mode: file.mode,
                                    filesLeft: files.count - fileIndex, bytesLeft: remaining)
        sendHeader(ZHeader(type: ZType.file, f0: options.resume ? ZConversion.resume : ZConversion.binary))
        send(ZFrame.subpacket(info, end: ZEnd.crcW, crc32: crc32, escaper: &escaper))
        phase = .waitFileResponse
        fileSentAt = clock.now
        arm(options.headerTimeout)
    }

    private func resend(_ reason: String, _ action: () -> Void) {
        retries += 1
        if retries > options.maxRetries {
            fail("too many retries (\(reason))")
            return
        }
        emit(.recovered(reason))
        action()
    }

    private func rewind(to offset: Int) {
        let target = min(max(0, offset), file.size)
        if phase == .waitFileResponse {
            fileAccepted = true
            retries = 0
            if target > 0 { emit(.log("receiver resumes \(file.name) at \(target)")) }
        } else {
            if target <= furthestRewind {
                rewindsWithoutProgress += 1
                if rewindsWithoutProgress > 20 {
                    fail("the receiver keeps asking for \(target)")
                    return
                }
            } else {
                rewindsWithoutProgress = 0
            }
            emit(.recovered("ZRPOS \(target)"))
            progress.sessionBytes -= max(0, position - target)
        }
        furthestRewind = max(furthestRewind, target)
        position = target
        progress.fileBytes = position
        startData()
    }

    private func startData() {
        sendHeader(ZHeader(type: ZType.data, position: position))
        bytesSinceAck = 0
        phase = .streaming
        disarm()
    }

    override func refill(_ budget: Int) {
        var produced = 0
        while phase == .streaming, status == .running, produced < budget {
            var count = min(blockSize, file.size - position)
            if receiverBuffer > 0 { count = min(count, receiverBuffer - bytesSinceAck) }
            let data: [UInt8]
            do { data = try file.read(offset: position, count: count) } catch {
                fail("cannot read \(file.name): \(error)")
                return
            }
            guard data.count == count else {
                fail("\(file.name) changed while it was being sent")
                return
            }
            let last = position + count >= file.size
            let windowFull = receiverBuffer > 0 && bytesSinceAck + count >= receiverBuffer
            let end = last ? ZEnd.crcE : (windowFull ? ZEnd.crcW : ZEnd.crcG)
            let packet = ZFrame.subpacket(data, end: end, crc32: crc32, escaper: &escaper)
            send(packet)
            produced += packet.count
            position += count
            bytesSinceAck += count
            progress.fileBytes = position
            progress.sessionBytes += count
            if last {
                sendHeader(ZHeader(type: ZType.eof, position: position))
                phase = .waitEOFResponse
                arm(options.headerTimeout)
            } else if windowFull {
                phase = .waitDataAck
                arm(options.headerTimeout)
            }
        }
    }

    private func fileDone() {
        emit(.fileCompleted(TransferredFile(name: file.name, remoteName: file.name, bytes: file.size, sha256: finalHash(file))))
        progress.filesCompleted += 1
        nextFile()
    }

    private func nextFile() {
        fileIndex += 1
        fileAccepted = false
        retries = 0
        phase = .waitRInit
        sendFile()
    }

    private func sendFin() {
        send(ZFrame.hexHeader(ZHeader(type: ZType.fin)))
        phase = .waitFinAck
        arm(options.headerTimeout)
    }

    override func timedOut() {
        switch phase {
        case .waitRInit:
            if retries >= options.maxRetries {
                fail("no ZMODEM receiver answered")
                return
            }
            resend("no ZRINIT") {
                self.send(ZFrame.hexHeader(ZHeader(type: ZType.rqinit)))
                self.arm(self.options.headerTimeout)
            }
        case .waitSInitAck:
            resend("no ZACK for ZSINIT") { self.sendSInit() }
        case .waitFileResponse:
            resend("no answer to ZFILE") { self.sendFile() }
        case .waitDataAck:
            resend("no ZACK") {
                self.position -= self.bytesSinceAck
                self.progress.sessionBytes -= self.bytesSinceAck
                self.startData()
            }
        case .waitEOFResponse:
            resend("no answer to ZEOF") {
                self.sendHeader(ZHeader(type: ZType.eof, position: self.position))
                self.arm(self.options.headerTimeout)
            }
        case .waitFinAck:
            if retries >= 2 {
                emit(.log("no ZFIN from the receiver; every file was confirmed"))
                send(Array("OO".utf8))
                complete()
            } else {
                resend("no ZFIN") { self.sendFin() }
            }
        case .streaming:
            break
        }
    }
}

/// Receives files with ZMODEM.
public final class ZModemReceiver: TransferEngine {
    let sink: TransferSink

    private enum Phase { case waitHeader, fileInfo, sinitData, commandData, data, finishing }
    private var phase = Phase.waitHeader
    private let reader = ZReader()
    private var fileHeader = ZHeader(type: ZType.file)
    private var fileOpen = false
    private var fileName = ""
    private var announcedSize: Int?
    private var offset = 0
    private var retries = 0
    private var errorsAtOffset = 0
    private var lastErrorOffset = -1
    /// A ZRPOS went out; ignore damaged frames until the sender's new ZDATA arrives.
    private var awaitingDataHeader = false
    private var finishingOs = 0
    private var lastSent: [UInt8] = []

    public override var protocolName: String { "ZMODEM" }

    public init(sink: TransferSink, clock: TransferClock, options: TransferOptions = TransferOptions()) {
        self.sink = sink
        super.init(clock: clock, options: options)
    }

    private var rinit: ZHeader {
        var flags = ZCapability.canFullDuplex | ZCapability.canOverlapIO
        if options.zmodemUseCRC32 { flags |= ZCapability.canCRC32 }
        if options.zmodemEscapeControl { flags |= ZCapability.escapeControl }
        let window = min(0xFFFF, max(0, options.zmodemReceiveWindow))
        return ZHeader(type: ZType.rinit, bytes: [UInt8(window & 0xFF), UInt8(window >> 8), 0, flags])
    }

    private func sendHex(_ header: ZHeader) {
        lastSent = ZFrame.hexHeader(header)
        send(lastSent)
    }

    override func begin() {
        sendHex(rinit)
        arm(options.headerTimeout)
    }

    override func handle(_ bytes: [UInt8]) {
        if phase == .finishing {
            for byte in bytes where byte == UInt8(ascii: "O") {
                finishingOs += 1
                if finishingOs >= 2 {
                    complete()
                    return
                }
            }
        }
        var tokens: [ZToken] = []
        reader.feed(bytes) { tokens.append($0) }
        for token in tokens where status == .running {
            switch token {
            case .cancel:
                fail("cancelled by the sender", cancelRemote: false)
            case .header(let header, _):
                handleHeader(header)
            case .data(let data, let end):
                handleData(data, end: end)
            case .badHeader(let reason), .badData(let reason):
                if fileOpen, phase == .data || awaitingDataHeader || phase == .waitHeader {
                    requestPosition(reason)
                } else if phase == .fileInfo {
                    phase = .waitHeader
                    sendHex(rinit)
                    arm(options.headerTimeout)
                }
            }
        }
    }

    private func handleHeader(_ header: ZHeader) {
        switch header.type {
        case ZType.rqinit:
            if !fileOpen, phase != .finishing { sendHex(rinit) }
        case ZType.sinit:
            phase = .sinitData
        case ZType.file:
            fileHeader = header
            phase = .fileInfo
        case ZType.data:
            guard fileOpen else {
                reader.resetToHeaders()
                return
            }
            if header.position != offset {
                reader.resetToHeaders()
                if !awaitingDataHeader { requestPosition("data at \(header.position), expected \(offset)") }
                return
            }
            awaitingDataHeader = false
            phase = .data
            arm(options.headerTimeout)
        case ZType.eof:
            if fileOpen {
                // An EOF at the wrong place may have crossed our ZRPOS; ignore it (as lrzsz does).
                guard header.position == offset else { return }
                finishFile()
                guard status == .running else { return }
                phase = .waitHeader
                sendHex(rinit)
                arm(options.headerTimeout)
            } else if phase == .waitHeader {
                sendHex(rinit)
            }
        case ZType.fin:
            if fileOpen {
                sink.abort(resumable: true)
                fileOpen = false
            }
            sendHex(ZHeader(type: ZType.fin))
            phase = .finishing
            arm(1)
        case ZType.command:
            phase = .commandData
        case ZType.freecnt:
            sendHex(ZHeader(type: ZType.ack, position: 0x7FFF_FFFF))
        case ZType.challenge:
            sendHex(ZHeader(type: ZType.ack, bytes: header.bytes))
        case ZType.nak:
            if !lastSent.isEmpty { send(lastSent) }
        case ZType.abort, ZType.ferr, ZType.can:
            fail("the sender stopped (\(ZType.name(header.type)))", cancelRemote: false)
        default:
            break
        }
    }

    private func handleData(_ data: [UInt8], end: UInt8) {
        switch phase {
        case .fileInfo:
            phase = .waitHeader
            if fileOpen {
                // The sender did not get our answer to this file and sent ZFILE again.
                sendHex(ZHeader(type: ZType.rpos, position: offset))
                arm(options.headerTimeout)
                return
            }
            guard let info = ZFileInfo.parse(data) else {
                sendHex(ZHeader(type: ZType.skip))
                emit(.fileSkipped(name: "?", reason: "unreadable ZFILE information"))
                return
            }
            openFile(info)
        case .sinitData:
            phase = .waitHeader
            sendHex(ZHeader(type: ZType.ack))
            arm(options.headerTimeout)
        case .commandData:
            phase = .waitHeader
            let command = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            emit(.log("refused a remote command (ZCOMMAND \"\(command)\"); commands are never run"))
            sendHex(ZHeader(type: ZType.compl, position: 1))
            arm(options.headerTimeout)
        case .data:
            guard fileOpen else { return }
            if !data.isEmpty {
                do { try sink.write(data) } catch {
                    fail("\(error)")
                    return
                }
                offset += data.count
                progress.fileBytes = offset
                progress.sessionBytes += data.count
            }
            retries = 0
            if offset > lastErrorOffset { errorsAtOffset = 0 }
            switch end {
            case ZEnd.crcQ:
                sendHex(ZHeader(type: ZType.ack, position: offset))
            case ZEnd.crcW:
                sendHex(ZHeader(type: ZType.ack, position: offset))
                phase = .waitHeader
            case ZEnd.crcE:
                phase = .waitHeader
            default:
                break
            }
            arm(options.headerTimeout)
        default:
            break
        }
    }

    private func openFile(_ info: ZFileInfo.Info) {
        let resume = fileHeader.f0 == ZConversion.resume || options.resume
        fileName = info.name
        announcedSize = info.size
        progress.fileName = info.name
        progress.fileSize = info.size
        switch sink.open(FileOffer(name: info.name, size: info.size, modified: info.modified, mode: info.mode, resumeRequested: resume)) {
        case .accept(let start):
            fileOpen = true
            offset = start
            progress.fileBytes = start
            lastErrorOffset = -1
            errorsAtOffset = 0
            emit(.fileStarted(name: info.name, size: info.size, offset: start))
            sendHex(ZHeader(type: ZType.rpos, position: start))
            awaitingDataHeader = true
            phase = .waitHeader
            arm(options.headerTimeout)
        case .skip(let reason):
            emit(.fileSkipped(name: info.name, reason: reason))
            sendHex(ZHeader(type: ZType.skip))
            arm(options.headerTimeout)
        }
    }

    /// Asks the sender to continue from our offset after damage or a gap.
    private func requestPosition(_ reason: String) {
        reader.resetToHeaders()
        if awaitingDataHeader { return }
        if offset == lastErrorOffset {
            errorsAtOffset += 1
            if errorsAtOffset > 20 {
                fail("too many errors at offset \(offset)")
                return
            }
        } else {
            lastErrorOffset = offset
            errorsAtOffset = 1
        }
        emit(.recovered("\(reason); asking for \(offset)"))
        sendHex(ZHeader(type: ZType.rpos, position: offset))
        awaitingDataHeader = true
        phase = .waitHeader
        arm(options.headerTimeout)
    }

    private func finishFile() {
        fileOpen = false
        let st = reader.stats
        emit(.log("frames so far: headers \(st.hexHeaders) hex, \(st.bin16Headers) bin16, \(st.bin32Headers) bin32; "
                  + "\(st.subpackets) subpackets (ZCRCE \(st.ends[0]), ZCRCG \(st.ends[1]), ZCRCQ \(st.ends[2]), ZCRCW \(st.ends[3])), "
                  + "longest \(st.longestSubpacket); \(st.escapedBytes) of \(st.dataBytes) data bytes arrived escaped"))
        if let size = announcedSize, size != offset { emit(.log("\(fileName) ended at \(offset), announced \(size)")) }
        do {
            let file = try sink.finish()
            progress.filesCompleted += 1
            emit(.fileCompleted(file))
        } catch {
            fail("\(error)")
        }
    }

    override func abortCurrentFile() {
        if fileOpen { sink.abort(resumable: true) }
        fileOpen = false
    }

    override func timedOut() {
        if phase == .finishing {
            complete()
            return
        }
        retries += 1
        if retries > options.maxRetries {
            fail(fileOpen ? "the sender stopped sending" : "no ZMODEM sender answered")
            return
        }
        emit(.recovered("timeout"))
        if fileOpen {
            reader.resetToHeaders()
            sendHex(ZHeader(type: ZType.rpos, position: offset))
            awaitingDataHeader = true
            phase = .waitHeader
        } else {
            phase = .waitHeader
            sendHex(rinit)
        }
        arm(options.headerTimeout)
    }
}
