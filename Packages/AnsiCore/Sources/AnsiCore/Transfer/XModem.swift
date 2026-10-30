import Foundation

enum XModemByte {
    static let SOH: UInt8 = 0x01, STX: UInt8 = 0x02, EOT: UInt8 = 0x04, ACK: UInt8 = 0x06
    static let NAK: UInt8 = 0x15, CAN: UInt8 = 0x18, SUB: UInt8 = 0x1A
    static let wantCRC: UInt8 = 0x43, wantG: UInt8 = 0x47
}

/// The YMODEM block 0: `name NUL size mtime mode serial filesleft bytesleft NUL`, NUL padded.
public enum YModemHeader {
    public struct Info: Equatable, Sendable {
        public var name: String
        public var size: Int?
        public var modified: Date?
        public var mode: Int?
    }

    public static func parse(_ block: [UInt8]) -> Info? {
        guard !block.isEmpty else { return nil }
        guard let nameEnd = block.firstIndex(of: 0) else { return nil }
        let name = TransferFileName.decode(Array(block[..<nameEnd]))
        guard !name.isEmpty else { return Info(name: "") }
        let rest = block[(nameEnd + 1)...]
        let fieldEnd = rest.firstIndex(of: 0) ?? rest.endIndex
        let text = String(decoding: rest[rest.startIndex..<fieldEnd], as: UTF8.self)
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var info = Info(name: name)
        if fields.count > 0, let size = Int(fields[0]), size >= 0 { info.size = size }
        if fields.count > 1, let mtime = Int(fields[1], radix: 8), mtime > 0 { info.modified = Date(timeIntervalSince1970: TimeInterval(mtime)) }
        if fields.count > 2, let mode = Int(fields[2], radix: 8), mode > 0 { info.mode = mode }
        return info
    }

    public static func encode(name: String, size: Int, modified: Date?, mode: Int?, filesLeft: Int, bytesLeft: Int) -> [UInt8] {
        let mtime = modified.map { max(0, Int($0.timeIntervalSince1970)) } ?? 0
        let fields = "\(size) \(String(mtime, radix: 8)) \(String(mode ?? 0, radix: 8)) 0 \(filesLeft) \(bytesLeft)"
        var block = Array(name.utf8) + [0] + Array(fields.utf8) + [0]
        let length = block.count <= 128 ? 128 : 1024
        if block.count > length { block = Array(block.prefix(length - 1)) + [0] }
        return block + Array(repeating: 0, count: length - block.count)
    }
}

private func usesCRC(_ kind: TransferProtocolKind) -> Bool { kind != .xmodem }
private func usesBigBlocks(_ kind: TransferProtocolKind) -> Bool {
    kind == .xmodem1K || kind == .ymodem || kind == .ymodemG
}

func xmodemPacket(number: UInt8, data: [UInt8], length: Int, pad: UInt8, crc: Bool) -> [UInt8] {
    var packet: [UInt8] = [length == 1024 ? XModemByte.STX : XModemByte.SOH, number, ~number]
    packet.reserveCapacity(length + 5)
    packet += data
    if data.count < length { packet += Array(repeating: pad, count: length - data.count) }
    let body = packet[3...]
    if crc {
        let value = CRC16XMODEM.checksum(body)
        packet += [UInt8(value >> 8), UInt8(value & 0xFF)]
    } else {
        packet.append(TransferChecks.sum8(body))
    }
    return packet
}

/// Sends with XMODEM (checksum, CRC, 1K), YMODEM (batch) or YMODEM-G. The receiver chooses the
/// check: NAK means checksum, `C` CRC, `G` YMODEM-G streaming.
public final class XModemSender: TransferEngine {
    public let kind: TransferProtocolKind
    let files: [OutgoingFile]

    private enum Phase { case waitStart, waitHeaderAck, waitDataStart, waitDataAck, streaming, waitEOTAck, waitEndAck }
    private var phase = Phase.waitStart
    private var fileIndex = 0
    private var position = 0
    private var blockNumber: UInt8 = 1
    private var lastPacket: [UInt8] = []
    private var lastPacketData = 0
    private var crc = true
    private var gMode = false
    private var retries = 0
    private var cancelCount = 0
    private var fileHash = ""
    private var sentEndOfBatch = false

    public override var protocolName: String { kind.displayName }

    public init(kind: TransferProtocolKind, files: [OutgoingFile], clock: TransferClock, options: TransferOptions = TransferOptions()) {
        precondition(kind != .zmodem && kind != .kermit, "use the ZMODEM or Kermit engine")
        self.kind = kind
        self.files = kind.isBatch ? files : Array(files.prefix(1))
        super.init(clock: clock, options: options)
    }

    private var batch: Bool { kind.isBatch }
    private var file: OutgoingFile { files[fileIndex] }

    override func begin() {
        if files.isEmpty, !batch {
            fail("nothing to send", cancelRemote: false)
            return
        }
        if files.count < (kind.isBatch ? 0 : 1) { return }
        phase = .waitStart
        arm(options.senderStartTimeout)
        if !batch { prepareFile() }
    }

    private func prepareFile() {
        do { fileHash = try file.sha256() } catch {
            fail("cannot read \(file.name): \(error)")
            return
        }
        progress.fileName = file.name
        progress.fileSize = file.size
        progress.fileBytes = 0
        position = 0
        emit(.fileStarted(name: file.name, size: file.size, offset: 0))
    }

    override func handle(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count, status == .running {
            let byte = bytes[index]
            index += 1
            if byte == XModemByte.CAN {
                cancelCount += 1
                if cancelCount >= 2 { fail("cancelled by the receiver", cancelRemote: false) }
                continue
            }
            cancelCount = 0
            if process(byte) {
                // An ACK for a data block: anything after it in this read is a duplicate or noise
                // (the receiver says nothing until it sees the next block).
                index = bytes.count
            }
        }
    }

    /// Returns true when the rest of the current input should be dropped.
    private func process(_ byte: UInt8) -> Bool {
        switch phase {
        case .waitStart:
            guard byte == XModemByte.NAK || byte == XModemByte.wantCRC || (batch && byte == XModemByte.wantG) else { return false }
            crc = byte != XModemByte.NAK
            gMode = byte == XModemByte.wantG
            retries = 0
            if batch { sendHeader() } else { startData() }
        case .waitHeaderAck:
            if byte == XModemByte.ACK {
                retries = 0
                if sentEndOfBatch {
                    complete()
                } else {
                    phase = .waitDataStart
                    arm(options.blockTimeout)
                }
            } else if byte == XModemByte.NAK || byte == XModemByte.wantCRC {
                resend("header refused")
            }
        case .waitDataStart:
            if byte == XModemByte.wantCRC || byte == XModemByte.NAK || byte == XModemByte.wantG { startData() }
        case .waitDataAck:
            if byte == XModemByte.ACK {
                retries = 0
                position += lastPacketData
                blockNumber &+= 1
                progress.fileBytes = position
                progress.sessionBytes += lastPacketData
                if position >= file.size { sendEOT() } else { sendBlock() }
                return true
            } else if byte == XModemByte.NAK || (byte == XModemByte.wantCRC && position == 0) {
                resend("block \(blockNumber) refused")
            }
        case .streaming:
            break
        case .waitEOTAck:
            if byte == XModemByte.ACK {
                fileDone()
            } else if byte == XModemByte.NAK {
                send(XModemByte.EOT)
                arm(options.blockTimeout)
            } else if batch, byte == XModemByte.wantCRC || byte == XModemByte.wantG {
                // The ACK was lost but the receiver already asks for the next header.
                fileDone()
                _ = process(byte)
            }
        case .waitEndAck:
            if byte == XModemByte.ACK { complete() } else if byte == XModemByte.wantCRC || byte == XModemByte.NAK { resend("end of batch refused") }
        }
        return false
    }

    private func resend(_ reason: String) {
        retries += 1
        if retries > options.maxRetries {
            fail("too many retries (\(reason))")
            return
        }
        emit(.recovered(reason))
        send(lastPacket)
        arm(ackTimeout)
    }

    /// The sender waits longer than the receiver's NAK timer, so retries are driven by the
    /// receiver and the two sides never time out together (which would let a stale ACK
    /// advance the sender past a block the receiver does not have).
    private var ackTimeout: TimeInterval { options.blockTimeout * 2 }

    private func sendHeader() {
        if fileIndex < files.count {
            prepareFile()
            guard status == .running else { return }
            let remaining = files[fileIndex...].reduce(0) { $0 + $1.size }
            let header = YModemHeader.encode(name: file.name, size: file.size, modified: file.modified, mode: file.mode,
                                             filesLeft: files.count - fileIndex, bytesLeft: remaining)
            lastPacket = xmodemPacket(number: 0, data: header, length: header.count, pad: 0, crc: crc)
            sentEndOfBatch = false
        } else {
            lastPacket = xmodemPacket(number: 0, data: [], length: 128, pad: 0, crc: crc)
            sentEndOfBatch = true
        }
        send(lastPacket)
        if gMode {
            if sentEndOfBatch { complete() } else {
                phase = .waitDataStart
                arm(options.blockTimeout)
            }
        } else {
            phase = sentEndOfBatch ? .waitEndAck : .waitHeaderAck
            arm(options.blockTimeout)
        }
    }

    private func startData() {
        blockNumber = 1
        position = 0
        retries = 0
        if file.size == 0 {
            sendEOT()
        } else if gMode {
            phase = .streaming
            disarm()
        } else {
            sendBlock()
        }
    }

    private func nextPacket() -> (packet: [UInt8], count: Int)? {
        let remaining = file.size - position
        let length = usesBigBlocks(kind) && remaining > 896 ? 1024 : 128
        do {
            let data = try file.read(offset: position, count: length)
            guard !data.isEmpty else {
                fail("\(file.name) ended early")
                return nil
            }
            return (xmodemPacket(number: blockNumber, data: data, length: length, pad: XModemByte.SUB, crc: crc), data.count)
        } catch {
            fail("cannot read \(file.name): \(error)")
            return nil
        }
    }

    private func sendBlock() {
        guard let next = nextPacket() else { return }
        lastPacket = next.packet
        lastPacketData = next.count
        send(next.packet)
        phase = .waitDataAck
        arm(ackTimeout)
    }

    override func refill(_ budget: Int) {
        var produced = 0
        while phase == .streaming, status == .running, produced < budget {
            if position >= file.size {
                sendEOT()
                break
            }
            guard let next = nextPacket() else { return }
            send(next.packet)
            produced += next.packet.count
            position += next.count
            blockNumber &+= 1
            progress.fileBytes = position
            progress.sessionBytes += next.count
        }
    }

    private func sendEOT() {
        lastPacket = [XModemByte.EOT]
        send(XModemByte.EOT)
        phase = .waitEOTAck
        arm(ackTimeout)
    }

    private func fileDone() {
        emit(.fileCompleted(TransferredFile(name: file.name, remoteName: file.name, bytes: file.size, sha256: fileHash)))
        progress.filesCompleted += 1
        progress.fileBytes = file.size
        fileIndex += 1
        retries = 0
        if !batch {
            complete()
        } else {
            phase = .waitStart
            arm(options.senderStartTimeout)
        }
    }

    override func timedOut() {
        switch phase {
        case .waitStart:
            fail(progress.filesCompleted == 0 ? "the receiver never asked for data" : "the receiver stopped asking for files")
        case .waitDataStart:
            // As lrzsz does: the receiver's start character may be lost, so go ahead.
            startData()
        case .waitEndAck where retries >= 1:
            // Every file was already confirmed (its EOT was ACKed); only the ACK of the empty
            // end of batch block is missing, and the receiver may simply have gone.
            emit(.log("no ACK for the end of batch block; all files were confirmed"))
            complete()
        case .waitHeaderAck, .waitDataAck, .waitEOTAck, .waitEndAck:
            resend("timeout")
        case .streaming:
            break
        }
    }
}

/// Receives XMODEM (checksum, CRC, 1K), YMODEM (batch) or YMODEM-G.
public final class XModemReceiver: TransferEngine {
    public let kind: TransferProtocolKind
    let sink: TransferSink
    /// The name plain XMODEM files are stored under (XMODEM carries no name).
    public let xmodemFileName: String

    private enum Phase { case starting, ready, packet, purging }
    private var phase = Phase.starting
    private var startChar: UInt8
    private var startsSent = 0
    private var crc: Bool
    private let gMode: Bool
    private var expectedBlock: UInt8
    private var awaitingHeader: Bool
    private var packet: [UInt8] = []
    private var packetSize = 0
    private var dataLength = 0
    private var fileOpen = false
    private var skipping = false
    private var fileName = ""
    private var remaining: Int?
    private var held: [UInt8]?
    private var retries = 0
    private var cancelCount = 0
    private var eotCount = 0
    private var gotBlock = false
    /// A block start arrived, even a damaged one: the sender answered our C, so no fallback to
    /// checksum (switching then would misframe every later block).
    private var heardBlockStart = false

    public override var protocolName: String { kind.displayName }

    public init(kind: TransferProtocolKind, sink: TransferSink, clock: TransferClock,
                options: TransferOptions = TransferOptions(), xmodemFileName: String = "download.bin") {
        precondition(kind != .zmodem && kind != .kermit, "use the ZMODEM or Kermit engine")
        self.kind = kind
        self.sink = sink
        self.xmodemFileName = xmodemFileName
        gMode = kind == .ymodemG
        startChar = kind == .xmodem ? XModemByte.NAK : (gMode ? XModemByte.wantG : XModemByte.wantCRC)
        crc = usesCRC(kind)
        expectedBlock = kind.isBatch ? 0 : 1
        awaitingHeader = kind.isBatch
        super.init(clock: clock, options: options)
    }

    private var batch: Bool { kind.isBatch }

    override func begin() {
        sendStart()
    }

    private func sendStart() {
        if !batch, crc, startsSent >= 3, !heardBlockStart {
            // The classic fallback: a sender that ignores C gets NAK (checksum).
            crc = false
            startChar = XModemByte.NAK
        }
        send(startChar)
        startsSent += 1
        arm(options.startInterval)
    }

    override func handle(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count, status == .running {
            let byte = bytes[index]
            switch phase {
            case .packet:
                let take = min(packetSize - packet.count, bytes.count - index)
                packet += bytes[index..<(index + take)]
                index += take
                if packet.count == packetSize { processPacket() }
                continue
            case .purging:
                if byte == XModemByte.CAN {
                    cancelCount += 1
                    if cancelCount >= 2 { fail("cancelled by the sender", cancelRemote: false) }
                } else {
                    cancelCount = 0
                }
                arm(options.purgeTime)
            case .starting, .ready:
                if byte == XModemByte.SOH || byte == XModemByte.STX {
                    cancelCount = 0
                    heardBlockStart = true
                    dataLength = byte == XModemByte.STX ? 1024 : 128
                    packetSize = 2 + dataLength + (crc ? 2 : 1)
                    packet.removeAll(keepingCapacity: true)
                    phase = .packet
                    arm(options.blockTimeout)
                } else if byte == XModemByte.EOT {
                    cancelCount = 0
                    handleEOT()
                } else if byte == XModemByte.CAN {
                    cancelCount += 1
                    if cancelCount >= 2 { fail("cancelled by the sender", cancelRemote: false) }
                } else {
                    cancelCount = 0
                    if phase == .ready, gotBlock || !awaitingHeader {
                        // Noise between blocks: wait for the line to go quiet, then NAK.
                        startPurge("noise between blocks")
                    }
                }
            }
            index += 1
        }
    }

    private func startPurge(_ reason: String) {
        if gMode {
            fail("YMODEM-G stream error (\(reason)); YMODEM-G cannot recover")
            return
        }
        retries += 1
        if retries > options.maxRetries {
            fail("too many errors (\(reason))")
            return
        }
        emit(.recovered(reason))
        phase = .purging
        arm(options.purgeTime)
    }

    private func processPacket() {
        phase = .ready
        gotBlock = true
        let number = packet[0]
        let data = Array(packet[2..<(2 + dataLength)])
        var valid = number == ~packet[1]
        if valid {
            if crc {
                let value = CRC16XMODEM.checksum(data)
                valid = packet[2 + dataLength] == UInt8(value >> 8) && packet[3 + dataLength] == UInt8(value & 0xFF)
            } else {
                valid = packet[2 + dataLength] == TransferChecks.sum8(data)
            }
        }
        guard valid else {
            startPurge("bad block (check failed)")
            return
        }
        if awaitingHeader {
            if number == 0 {
                handleHeader(data)
            } else if number == expectedBlock &- 1, !gMode {
                send(XModemByte.ACK)
                arm(options.blockTimeout)
            } else {
                fail("expected a YMODEM header, got block \(number)")
            }
            return
        }
        if number == expectedBlock {
            accept(data)
        } else if number == expectedBlock &- 1 {
            emit(.recovered("duplicate block \(number)"))
            if !gMode {
                send(XModemByte.ACK)
                if batch, number == 0 { send(startChar) }
            }
            arm(options.blockTimeout)
        } else {
            fail("block \(number) out of sequence (expected \(expectedBlock))")
        }
    }

    private func openXModemFileIfNeeded() -> Bool {
        guard !fileOpen, !batch else { return true }
        fileName = xmodemFileName
        switch sink.open(FileOffer(name: xmodemFileName)) {
        case .accept:
            fileOpen = true
            progress.fileName = fileName
            emit(.fileStarted(name: fileName, size: nil, offset: 0))
            return true
        case .skip(let reason):
            fail("cannot store the file: \(reason)")
            return false
        }
    }

    private func accept(_ data: [UInt8]) {
        guard openXModemFileIfNeeded() else { return }
        if batch {
            let count = remaining.map { min($0, data.count) } ?? data.count
            write(Array(data.prefix(count)))
            if remaining != nil { remaining! -= count }
        } else {
            if let previous = held { write(previous) }
            held = data
        }
        guard status == .running else { return }
        expectedBlock &+= 1
        retries = 0
        eotCount = 0
        if !gMode { send(XModemByte.ACK) }
        arm(options.blockTimeout)
    }

    private func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        progress.fileBytes += bytes.count
        progress.sessionBytes += bytes.count
        guard !skipping else { return }
        do { try sink.write(bytes) } catch {
            fail("\(error)")
        }
    }

    private func handleHeader(_ data: [UInt8]) {
        guard let info = YModemHeader.parse(data) else {
            fail("unreadable YMODEM header")
            return
        }
        if info.name.isEmpty {
            if !gMode { send(XModemByte.ACK) }
            complete()
            return
        }
        fileName = info.name
        remaining = info.size
        progress.fileName = info.name
        progress.fileSize = info.size
        progress.fileBytes = 0
        switch sink.open(FileOffer(name: info.name, size: info.size, modified: info.modified, mode: info.mode)) {
        case .accept:
            fileOpen = true
            skipping = false
            emit(.fileStarted(name: info.name, size: info.size, offset: 0))
        case .skip(let reason):
            // YMODEM cannot skip a file; it is received and thrown away.
            fileOpen = true
            skipping = true
            emit(.fileSkipped(name: info.name, reason: reason))
        }
        expectedBlock = 1
        awaitingHeader = false
        eotCount = 0
        retries = 0
        if !gMode { send(XModemByte.ACK) }
        send(startChar)
        arm(options.blockTimeout)
    }

    private func handleEOT() {
        if awaitingHeader {
            if gotBlock {
                // Our ACK of the last EOT was lost.
                send(XModemByte.ACK)
                send(startChar)
                arm(options.blockTimeout)
            }
            return
        }
        if batch, !gMode, eotCount == 0 {
            // YMODEM: NAK the first EOT, ACK the repeat (a lone noise EOT cannot end the file).
            eotCount = 1
            send(XModemByte.NAK)
            arm(options.blockTimeout)
            return
        }
        send(XModemByte.ACK)
        finishFile()
        guard status == .running else { return }
        if batch {
            awaitingHeader = true
            expectedBlock = 0
            eotCount = 0
            send(startChar)
            arm(options.blockTimeout)
        } else {
            complete()
        }
    }

    private func finishFile() {
        guard openXModemFileIfNeeded() else { return }
        if var last = held {
            if options.xmodemPadding == .stripTrailingSUB {
                while last.last == XModemByte.SUB { last.removeLast() }
            }
            held = nil
            write(last)
            guard status == .running else { return }
        }
        fileOpen = false
        if skipping {
            skipping = false
            return
        }
        if let left = remaining, left > 0 { emit(.log("\(fileName) ended \(left) bytes short of its announced size")) }
        do {
            let file = try sink.finish()
            progress.filesCompleted += 1
            emit(.fileCompleted(file))
        } catch {
            fail("\(error)")
        }
    }

    override func abortCurrentFile() {
        if fileOpen, !skipping { sink.abort(resumable: false) }
        fileOpen = false
        held = nil
    }

    override func timedOut() {
        switch phase {
        case .starting:
            if startsSent >= options.startTries {
                fail("no answer from the sender")
            } else {
                sendStart()
            }
        case .purging:
            phase = .ready
            cancelCount = 0
            send(awaitingHeader ? startChar : XModemByte.NAK)
            arm(options.blockTimeout)
        case .ready, .packet:
            if gMode, !awaitingHeader {
                fail("YMODEM-G stream stopped")
                return
            }
            retries += 1
            if retries > options.maxRetries {
                fail("timed out waiting for the sender")
                return
            }
            emit(.recovered("timeout"))
            phase = .ready
            send(awaitingHeader ? startChar : XModemByte.NAK)
            arm(options.blockTimeout)
        }
    }
}
