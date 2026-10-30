/// Plain words about the file transfer protocols, for tooltips, (?) popovers and the editor.
public enum TransferHelp {
    /// One or two sentences: what the protocol is and when to pick it.
    public static func hint(_ kind: TransferProtocolKind) -> String {
        switch kind {
        case .xmodem:
            return "The oldest protocol: one file, 128 byte blocks and a simple checksum. Use it only when the BBS offers nothing better."
        case .xmodemCRC:
            return "XMODEM with a stronger CRC check, one file at a time. Choose it over plain XMODEM when the BBS lists both."
        case .xmodem1K:
            return "XMODEM-CRC with 1024 byte blocks, so it is faster on a good line. It sends one file and no file name."
        case .ymodem:
            return "Sends several files with their names and sizes in 1024 byte blocks. A good choice when the BBS has no ZMODEM."
        case .ymodemG:
            return "YMODEM that does not wait for each block to be confirmed, so it is very fast. Any line error stops it, so use it only on a clean connection."
        case .zmodem:
            return "The best choice: pick it if the BBS offers it. It is fast, sends names and sizes, starts by itself and resumes an interrupted download."
        case .kermit:
            return "Slower but very robust, and it works on lines that are not 8 bit clean. Use it when the BBS suggests Kermit or when ZMODEM fails."
        }
    }

    /// Every protocol's hint, one per line, for the (?) popover.
    public static var allProtocols: String {
        TransferProtocolKind.allCases.map { "\($0.displayName): \(hint($0))" }.joined(separator: "\n\n")
    }

    public static let chooser = "Choose the protocol the BBS uses for this transfer. ZMODEM is best if the BBS offers it; otherwise YMODEM, then XMODEM-1K."
    public static let autoStart = "AnsiView saw the start of a file transfer. Accept if you asked the BBS to send or receive files; ignore it if this was ordinary text."
    public static let binaryWarning = "The BBS did not agree to telnet binary mode, so some bytes may be changed on the way. If the transfer fails, try Kermit or ZMODEM."
    public static let resume = "ZMODEM continues an interrupted download from where it stopped, as long as the partial file is still in the download folder."
    public static let cancel = "Stops the transfer and tells the BBS to stop too (Escape does the same). A partial ZMODEM download is kept so it can resume later."
    public static let folder = "Downloads from this BBS are saved here. AnsiView keeps your permission to write to the folder you chose."
    public static let xmodemName = "XMODEM does not send a file name, so type the name to save the file under."
}
