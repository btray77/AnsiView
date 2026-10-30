import AnsiCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// What the SSH transport asks the app about a server's host key (on the client's queue).
protocol HostKeyVerifying: AnyObject {
    /// Calls `done` with nil to go on, or the error that ends the connection.
    func verify(host: String, port: Int, key: Data, trustNew: Bool, done: @escaping (BBSConnectionError?) -> Void)
}

/// The ways the transport logs in, in the order tried (transports plan ruling 4).
struct SSHLogin {
    var username: String
    /// The Keychain password; nil sends the empty password (many BBSes accept it).
    var password: String?
    var key: SSHPrivateKey?

    /// The entry's username, or `guest` (SSH needs a name; BBSes ask again in their own login).
    static func username(for entry: BBSEntry) -> String {
        let name = entry.username?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "guest" : name
    }

    /// The entry's login: password from the Keychain, the key file through its bookmark (with its
    /// passphrase from the Keychain). `problem` says why a chosen key could not be used.
    static func load(entry: BBSEntry, passwords: PasswordStore?) -> (login: SSHLogin, problem: String?) {
        var login = SSHLogin(username: username(for: entry),
                             password: entry.credentialKey.flatMap { passwords?.password(for: $0) }, key: nil)
        guard let bookmark = entry.sshKeyBookmark else { return (login, nil) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            return (login, "The SSH key file could not be found. Choose it again in the dialing directory")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            return (login, "The SSH key file \(url.lastPathComponent) cannot be read")
        }
        let passphrase = entry.sshPassphraseKey.flatMap { passwords?.password(for: $0) }
        do {
            login.key = try SSHKeyFile.parse(data, passphrase: passphrase)
            return (login, nil)
        } catch let error as SSHKeyFileError {
            return (login, error.message)
        } catch {
            return (login, error.localizedDescription)
        }
    }
}

/// An SSH session to a BBS with swift-nio-ssh: PTY, shell, window change, public key / password /
/// none authentication and a host key check through `verifier`. Bytes pass unchanged both ways.
final class SSHTransport: BBSTransport {
    var events: ((TransportEvent) -> Void)?
    let host: String
    let port: Int
    let settings: TransportSettings
    private(set) var login: SSHLogin
    /// Reads the key file (and its passphrase) off the main thread when the connection starts.
    private let loadLogin: (() -> (login: SSHLogin, problem: String?))?
    /// Why the key file was not used (on the client's queue).
    var onLoginProblem: ((String) -> Void)?
    let connectTimeout: TimeInterval
    let queue: DispatchQueue
    weak var verifier: HostKeyVerifying?

    private var columns: Int
    private var rows: Int
    private var channel: Channel?
    private var session: Channel?
    private var opened = false
    private var done = false
    /// Set by the host key check, so the closed event names it instead of a generic error.
    private var hostKeyError: BBSConnectionError?
    /// The host key check waiting for the user; failed on close so NIO never sees it dropped.
    private var pendingHostKey: EventLoopPromise<Void>?

    init(host: String, port: Int, settings: TransportSettings, login: SSHLogin,
         loadLogin: (() -> (login: SSHLogin, problem: String?))? = nil, columns: Int, rows: Int,
         connectTimeout: TimeInterval = 15, queue: DispatchQueue, verifier: HostKeyVerifying?) {
        self.host = host
        self.port = port
        self.settings = settings
        self.login = login
        self.loadLogin = loadLogin
        self.columns = columns
        self.rows = rows
        self.connectTimeout = connectTimeout
        self.queue = queue
        self.verifier = verifier
    }

    func open() {
        guard channel == nil, !done else { return }
        guard let loadLogin else {
            start()
            return
        }
        // Decrypting a key file costs bcrypt rounds (milliseconds each): never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = loadLogin()
            self.queue.async {
                guard !self.done else { return }
                self.login = loaded.login
                if let problem = loaded.problem { self.onLoginProblem?(problem) }
                self.start()
            }
        }
    }

    private func start() {
        let authDelegate = AuthDelegate(login: login)
        let hostDelegate = HostKeyDelegate(transport: self)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.milliseconds(Int64(connectTimeout * 1000)))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostDelegate)),
                                            allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(ConnectionHandler(transport: self))
                }
            }
        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let channel):
                    if self.done { channel.close(promise: nil) } else { self.channel = channel }
                case .failure(let error):
                    self.finish(Self.map(error, host: self.host, port: self.port, connected: false))
                }
            }
        }
    }

    func write(_ bytes: [UInt8]) {
        guard let session, opened, !done, !bytes.isEmpty else { return }
        session.eventLoop.execute {
            var buffer = session.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            session.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        }
    }

    func write(_ bytes: [UInt8], completion: @escaping () -> Void) {
        guard let session, opened, !done, !bytes.isEmpty else {
            completion()
            return
        }
        let queue = self.queue
        session.eventLoop.execute {
            var buffer = session.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            let promise = session.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { _ in queue.async { completion() } }
            session.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: promise)
        }
    }

    func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        guard let session, opened, !done else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: columns, terminalRowHeight: rows,
                                                                 terminalPixelWidth: 0, terminalPixelHeight: 0)
        session.eventLoop.execute { session.triggerUserOutboundEvent(request, promise: nil) }
    }

    func close() {
        guard !done else { return }
        done = true
        pendingHostKey?.fail(HostKeyRefused())
        pendingHostKey = nil
        channel?.close(promise: nil)
        channel = nil
        session = nil
    }

    // MARK: Called from the NIO handlers (any thread)

    fileprivate func checkHostKey(_ key: NIOSSHPublicKey, promise: EventLoopPromise<Void>) {
        let text = String(openSSHPublicKey: key)
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            promise.fail(HostKeyRefused())
            return
        }
        queue.async {
            guard let verifier = self.verifier, !self.done else {
                self.hostKeyError = .hostKeyNotTrusted(self.host)
                promise.fail(HostKeyRefused())
                return
            }
            // An alert may wait for the user: the connect timeout pauses meanwhile.
            self.pendingHostKey = promise
            self.events?(.waitingForUser(true))
            verifier.verify(host: self.host, port: self.port, key: blob, trustNew: self.settings.sshTrustNewHostKey) { error in
                // An answer after the connection closed changes nothing (close() failed the promise).
                guard let pending = self.pendingHostKey, !self.done else { return }
                self.pendingHostKey = nil
                self.events?(.waitingForUser(false))
                if let error {
                    self.hostKeyError = error
                    pending.fail(HostKeyRefused())
                } else {
                    pending.succeed(())
                }
            }
        }
    }

    fileprivate func authenticated(_ channel: Channel) {
        // The size lives on the client's queue; read it there, then open the session on the loop.
        queue.async {
            let (columns, rows) = (self.columns, self.rows)
            channel.eventLoop.execute { self.openSession(channel, columns: columns, rows: rows) }
        }
    }

    private func openSession(_ channel: Channel, columns: Int, rows: Int) {
        let terminal = settings.terminalType.trimmingCharacters(in: .whitespaces)
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false, term: terminal.isEmpty ? "ansi" : terminal.lowercased(), terminalCharacterWidth: columns,
            terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        do {
            let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            ssh.createChannel(promise) { [weak self] child, type in
                guard type == .session else { return child.eventLoop.makeFailedFuture(SessionRefused()) }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SessionHandler(transport: self, pty: pty))
                }
            }
        } catch {
            promise.fail(error)
        }
        promise.futureResult.whenComplete { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let child): self.session = child
                case .failure: self.finish(.other("The SSH server would not open a session."))
                }
            }
        }
    }

    fileprivate func shellStarted() {
        queue.async {
            guard !self.done, !self.opened else { return }
            self.opened = true
            self.events?(.opened)
            if !self.early.isEmpty {
                let bytes = self.early
                self.early = []
                self.events?(.bytes(bytes))
            }
        }
    }

    /// Bytes that came before the shell's reply, passed on once the session counts as open.
    private var early: [UInt8] = []

    fileprivate func received(_ bytes: [UInt8]) {
        queue.async {
            guard !self.done else { return }
            if self.opened {
                self.events?(.bytes(bytes))
            } else if self.early.count < 1 << 20 {
                self.early += bytes
            }
        }
    }

    fileprivate func failed(_ error: Error) {
        queue.async {
            let mapped = self.hostKeyError ?? Self.map(error, host: self.host, port: self.port, connected: self.opened)
            self.finish(mapped)
        }
    }

    fileprivate func ended() {
        queue.async {
            self.finish(self.hostKeyError ?? (self.opened ? .closedByRemote : .other("The SSH server closed the connection before the session started.")))
        }
    }

    private func finish(_ error: BBSConnectionError?) {
        guard !done else { return }
        close()
        events?(.closed(error))
    }

    /// NIO and SSH failures in plain words.
    static func map(_ error: Error, host: String, port: Int, connected: Bool) -> BBSConnectionError {
        if let exhausted = error as? AuthExhausted { return .authenticationFailed(exhausted.detail) }
        if error is HostKeyRefused { return .hostKeyNotTrusted(host) }
        if error is SessionRefused { return .other("The SSH server logged you in but refused to start a terminal session.") }
        if let ssh = error as? NIOSSHError {
            switch ssh.type {
            case .keyExchangeNegotiationFailure:
                return .algorithmMismatch(host, "no key exchange method, host key type or cipher in common")
            case .invalidHostKeyForKeyExchange, .unknownPublicKey:
                return .algorithmMismatch(host, "its host key type")
            case .unsupportedVersion:
                return .algorithmMismatch(host, "it does not speak SSH version 2")
            case .tcpShutdown:
                return connected ? .closedByRemote : .other("The SSH server closed the connection during the handshake.")
            default:
                return .other("SSH error: \(ssh)")
            }
        }
        if let connect = error as? NIOConnectionError {
            if connect.connectionErrors.isEmpty, connect.dnsAError != nil || connect.dnsAAAAError != nil {
                return .hostNotFound(host)
            }
            if let first = connect.connectionErrors.first?.error { return map(first, host: host, port: port, connected: false) }
            return .hostNotFound(host)
        }
        if let io = error as? IOError {
            switch io.errnoCode {
            case ECONNREFUSED: return .refused(host, port)
            case ETIMEDOUT: return .timedOut(host)
            case ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN: return .unreachable(host)
            case ECONNRESET, EPIPE: return connected ? .closedByRemote : .refused(host, port)
            default: return .other(io.description)
            }
        }
        if let channel = error as? ChannelError {
            switch channel {
            case .connectTimeout: return .timedOut(host)
            case .ioOnClosedChannel, .alreadyClosed, .eof: return connected ? .closedByRemote : .other("The SSH connection closed.")
            default: return .other("\(channel)")
            }
        }
        if error is SocketAddressError { return .hostNotFound(host) }
        return .other(error.localizedDescription)
    }
}

struct AuthExhausted: Error {
    var detail: String
}

struct HostKeyRefused: Error {}
struct SessionRefused: Error {}

/// Offers the key, then the password (or an empty one), then `none`, each when the server lists it.
private final class AuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let login: SSHLogin
    private var triedKey = false
    private var triedPassword = false
    private var triedNone = false

    init(login: SSHLogin) {
        self.login = login
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if !triedKey, let key = login.key, availableMethods.contains(.publicKey) {
            triedKey = true
            let nioKey: NIOSSHPrivateKey
            switch key {
            case .ed25519(let k): nioKey = NIOSSHPrivateKey(ed25519Key: k)
            case .p256(let k): nioKey = NIOSSHPrivateKey(p256Key: k)
            case .p384(let k): nioKey = NIOSSHPrivateKey(p384Key: k)
            case .p521(let k): nioKey = NIOSSHPrivateKey(p521Key: k)
            }
            nextChallengePromise.succeed(.init(username: login.username, serviceName: "", offer: .privateKey(.init(privateKey: nioKey))))
            return
        }
        if !triedPassword, availableMethods.contains(.password) {
            triedPassword = true
            nextChallengePromise.succeed(.init(username: login.username, serviceName: "",
                                               offer: .password(.init(password: login.password ?? ""))))
            return
        }
        if !triedNone, !triedKey, !triedPassword {
            triedNone = true
            nextChallengePromise.succeed(.init(username: login.username, serviceName: "", offer: .none))
            return
        }
        var tried: [String] = []
        if triedKey { tried.append("the key file") }
        if triedPassword { tried.append(login.password == nil ? "an empty password (none is saved)" : "the saved password") }
        var detail = tried.isEmpty ? "AnsiView had no login method the server accepts."
            : "Tried \(tried.joined(separator: " and ")) as \(login.username)."
        if !availableMethods.contains(.password), !availableMethods.contains(.publicKey) {
            detail += " The server may want keyboard interactive login, which AnsiView's SSH does not support; use the BBS's telnet port."
        } else {
            detail += " Check the username and password in the dialing directory."
        }
        nextChallengePromise.fail(AuthExhausted(detail: detail))
    }
}

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    weak var transport: SSHTransport?

    init(transport: SSHTransport) {
        self.transport = transport
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let transport else {
            validationCompletePromise.fail(HostKeyRefused())
            return
        }
        transport.checkHostKey(hostKey, promise: validationCompletePromise)
    }
}

/// On the connection: starts the session after login, reports errors and the end.
private final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    weak var transport: SSHTransport?

    init(transport: SSHTransport?) {
        self.transport = transport
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            transport?.authenticated(context.channel)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        transport?.failed(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        transport?.ended()
        context.fireChannelInactive()
    }
}

/// On the session channel: PTY and shell requests, data both ways.
private final class SessionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    weak var transport: SSHTransport?
    let pty: SSHChannelRequestEvent.PseudoTerminalRequest

    init(transport: SSHTransport?, pty: SSHChannelRequestEvent.PseudoTerminalRequest) {
        self.transport = transport
        self.pty = pty
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        // A refused PTY is not fatal (the shell still runs); the shell's answer decides.
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            transport?.shellStarted()
        case is ChannelFailureEvent:
            transport?.failed(SessionRefused())
            context.close(promise: nil)
        case let input as ChannelEvent where input == .inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        // Standard error is shown too (a BBS has no other place for it).
        if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes), !bytes.isEmpty {
            transport?.received(bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The session ended (logoff): report it and close the connection too (the connection's
        // own inactive event is not relied on).
        transport?.ended()
        context.channel.parent?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        transport?.failed(error)
        context.close(promise: nil)
    }
}
