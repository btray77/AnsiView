// AnsiView patch (see PATCHES.md): the added key exchanges, ciphers, MACs and keyboard-interactive
// through the real NIOSSHHandler on both ends (client and server of this package), and the client
// side of RFC 4419 group exchange against a server computed in the test.

import Crypto
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSH

final class BBSCompatibilityTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        var negotiated: [NIOSSHNegotiatedAlgorithms] = []
        var authenticated = false
        var errors: [Error] = []
    }

    final class EventCatcher: ChannelInboundHandler {
        typealias InboundIn = Any
        let recorder: Recorder
        init(_ recorder: Recorder) { self.recorder = recorder }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if event is UserAuthSuccessEvent { self.recorder.authenticated = true }
            context.fireUserInboundEventTriggered(event)
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            self.recorder.errors.append(error)
        }
    }

    final class KeyboardInteractiveServer: NIOSSHServerUserAuthenticationDelegate, NIOSSHServerKeyboardInteractiveDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.keyboardInteractive]
        var answers: [[String]] = []

        func keyboardInteractiveChallenge(username: String) -> NIOSSHKeyboardInteractiveRequest? {
            .init(
                name: "BBS login",
                instruction: "Answer both",
                prompts: [.init(prompt: "Password: ", echo: false), .init(prompt: "Your handle: ", echo: true)]
            )
        }

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            guard case .keyboardInteractive(let answers) = request.request else {
                responsePromise.succeed(.failure)
                return
            }
            self.answers.append(answers.responses)
            responsePromise.succeed(answers.responses == ["sesame", "sysop"] ? .success : .failure)
        }
    }

    final class KeyboardInteractiveClient: NIOSSHClientUserAuthenticationDelegate, NIOSSHClientKeyboardInteractiveDelegate {
        var answers: [[String]]
        var requests: [NIOSSHKeyboardInteractiveRequest] = []
        var methodsSeen: [NIOSSHAvailableUserAuthenticationMethods] = []

        init(answers: [[String]]) { self.answers = answers }

        func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            self.methodsSeen.append(availableMethods)
            guard !self.answers.isEmpty else {
                nextChallengePromise.succeed(nil)
                return
            }
            nextChallengePromise.succeed(.init(username: "guest", serviceName: "", offer: .keyboardInteractive))
        }

        func respond(to request: NIOSSHKeyboardInteractiveRequest, responsePromise: EventLoopPromise<[String]>) {
            self.requests.append(request)
            responsePromise.succeed(self.answers.removeFirst())
        }
    }

    private func connect(
        clientKex: [String]? = nil,
        serverKex: [String]? = nil,
        serverSchemes: [NIOSSHTransportProtection.Type] = Constants.bundledTransportProtectionSchemes,
        clientAuth: NIOSSHClientUserAuthenticationDelegate = InfinitePasswordDelegate(),
        serverAuth: NIOSSHServerUserAuthenticationDelegate = DenyThenAcceptDelegate(messagesToDeny: 0)
    ) throws -> (Recorder, BackToBackEmbeddedChannel) {
        let channel = BackToBackEmbeddedChannel()
        let recorder = Recorder()
        var clientConfig = SSHClientConfiguration(
            userAuthDelegate: clientAuth,
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )
        clientConfig.keyExchangeAlgorithms = clientKex
        clientConfig.algorithmsNegotiated = { recorder.negotiated.append($0) }
        var serverConfig = SSHServerConfiguration(hostKeys: [.init(ed25519Key: .init())], userAuthDelegate: serverAuth)
        serverConfig.keyExchangeAlgorithms = serverKex
        serverConfig.transportProtectionSchemes = serverSchemes
        try channel.client.pipeline.syncOperations.addHandler(
            NIOSSHHandler(role: .client(clientConfig), allocator: channel.client.allocator, inboundChildChannelInitializer: nil)
        )
        try channel.client.pipeline.syncOperations.addHandler(EventCatcher(recorder))
        try channel.server.pipeline.syncOperations.addHandler(
            NIOSSHHandler(role: .server(serverConfig), allocator: channel.server.allocator, inboundChildChannelInitializer: nil)
        )
        try channel.activate()
        do {
            try channel.interactInMemory()
        } catch {
            recorder.errors.append(error)
        }
        return (recorder, channel)
    }

    func testModernAlgorithmsStayPreferred() throws {
        let (recorder, _) = try self.connect()
        XCTAssertTrue(recorder.authenticated)
        let negotiated = try XCTUnwrap(recorder.negotiated.first)
        XCTAssertEqual(negotiated.keyExchange, "curve25519-sha256")
        XCTAssertEqual(negotiated.hostKey, "ssh-ed25519")
        XCTAssertEqual(negotiated.cipher, "aes256-gcm@openssh.com")
        XCTAssertNil(negotiated.mac)
        XCTAssertFalse(negotiated.isLegacy)
    }

    func testEveryFixedGroupKeyExchange() throws {
        for name in [
            "diffie-hellman-group16-sha512", "diffie-hellman-group14-sha256", "diffie-hellman-group14-sha1",
            "diffie-hellman-group1-sha1",
        ] {
            let (recorder, _) = try self.connect(serverKex: [name])
            XCTAssertTrue(recorder.authenticated, name)
            XCTAssertEqual(recorder.negotiated.first?.keyExchange, name)
            XCTAssertEqual(recorder.negotiated.first?.isLegacy, name.hasSuffix("sha1"), name)
        }
    }

    func testServerNeverOffersGroupExchange() throws {
        let (recorder, _) = try self.connect(serverKex: ["diffie-hellman-group-exchange-sha256"])
        XCTAssertFalse(recorder.authenticated)
        let error = try XCTUnwrap(recorder.errors.first as? NIOSSHError)
        XCTAssertEqual(error.type, .keyExchangeNegotiationFailure)
    }

    func testEveryLegacyCipherAndMACPair() throws {
        for scheme in AESCBCCTRSchemes.all {
            let (recorder, _) = try self.connect(serverSchemes: [scheme])
            let label = "\(scheme.cipherName) \(scheme.macName ?? "")"
            XCTAssertTrue(recorder.authenticated, label)
            XCTAssertEqual(recorder.negotiated.first?.cipher, scheme.cipherName, label)
            XCTAssertEqual(recorder.negotiated.first?.mac, scheme.macName, label)
            // CBC, 3DES, SHA-1 and MD5 count as weak; AES-CTR with SHA-2 does not.
            let weak =
                scheme.cipherName.hasSuffix("-cbc") || (scheme.macName ?? "").contains("sha1")
                || (scheme.macName ?? "").contains("md5")
            XCTAssertEqual(recorder.negotiated.first?.isLegacy, weak, label)
            XCTAssertEqual(recorder.negotiated.first?.weakAlgorithms.isEmpty, !weak, label)
        }
    }

    func testNegotiationFailureNamesTheCategoryAndTheOffer() throws {
        func failure(_ change: (inout SSHMessage.KeyExchangeMessage) -> Void) -> String? {
            var client = self.clientMachine(Recorder())
            client.send(keyExchange: client.createKeyExchangeMessage())
            var offer = self.serverKexInit("diffie-hellman-group14-sha1")
            change(&offer)
            do {
                _ = try client.handle(keyExchange: offer)
                return nil
            } catch let error as NIOSSHError {
                XCTAssertEqual(error.type, .keyExchangeNegotiationFailure)
                return error.diagnosticMessage
            } catch {
                return "\(error)"
            }
        }
        XCTAssertEqual(failure { $0.keyExchangeAlgorithms = ["sntrup761x25519-sha512", "diffie-hellman-group18-sha512"] },
                       "key exchange: sntrup761x25519-sha512,diffie-hellman-group18-sha512")
        XCTAssertEqual(failure { $0.serverHostKeyAlgorithms = ["x509v3-sign-rsa"] }, "host key: x509v3-sign-rsa")
        XCTAssertEqual(failure { $0.encryptionAlgorithmsServerToClient = ["blowfish-cbc"]; $0.encryptionAlgorithmsClientToServer = ["blowfish-cbc"] },
                       "cipher: blowfish-cbc")
        XCTAssertEqual(failure { $0.macAlgorithmsServerToClient = ["umac-64@openssh.com"]; $0.macAlgorithmsClientToServer = ["umac-64@openssh.com"] },
                       "MAC: umac-64@openssh.com")
        XCTAssertNil(failure { _ in })
    }

    func testKeyboardInteractiveLogin() throws {
        let server = KeyboardInteractiveServer()
        let client = KeyboardInteractiveClient(answers: [["wrong", "sysop"], ["sesame", "sysop"]])
        let (recorder, _) = try self.connect(clientAuth: client, serverAuth: server)
        XCTAssertTrue(recorder.authenticated)
        XCTAssertEqual(server.answers, [["wrong", "sysop"], ["sesame", "sysop"]])
        XCTAssertEqual(client.requests.first?.name, "BBS login")
        XCTAssertEqual(client.requests.first?.prompts.map(\.echo), [false, true])
        // After the first wrong answer the server lists keyboard-interactive again.
        XCTAssertTrue(client.methodsSeen.last?.contains(.keyboardInteractive) ?? false)
    }

    func testKeyboardInteractiveWithoutAResponderSendsEmptyAnswers() throws {
        let server = KeyboardInteractiveServer()
        final class PlainClient: NIOSSHClientUserAuthenticationDelegate {
            var tries = 0
            func nextAuthenticationType(
                availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
            ) {
                self.tries += 1
                nextChallengePromise.succeed(
                    self.tries == 1 ? .init(username: "guest", serviceName: "", offer: .keyboardInteractive) : nil
                )
            }
        }
        let (recorder, _) = try self.connect(clientAuth: PlainClient(), serverAuth: server)
        XCTAssertFalse(recorder.authenticated)
        XCTAssertEqual(server.answers, [["", ""]])
    }

    // MARK: Group exchange, client side

    private func clientMachine(_ recorder: Recorder) -> SSHKeyExchangeStateMachine {
        var config = SSHClientConfiguration(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )
        config.algorithmsNegotiated = { recorder.negotiated.append($0) }
        return SSHKeyExchangeStateMachine(
            allocator: ByteBufferAllocator(),
            loop: EmbeddedEventLoop(),
            role: .client(config),
            remoteVersion: "SSH-2.0-cryptlib",
            protectionSchemes: Constants.bundledTransportProtectionSchemes,
            previousSessionIdentifier: nil
        )
    }

    private func serverKexInit(_ kex: Substring) -> SSHMessage.KeyExchangeMessage {
        .init(
            cookie: ByteBuffer(bytes: [UInt8](repeating: 7, count: 16)),
            keyExchangeAlgorithms: [kex],
            serverHostKeyAlgorithms: ["ssh-ed25519"],
            encryptionAlgorithmsClientToServer: ["aes128-cbc"],
            encryptionAlgorithmsServerToClient: ["aes128-cbc"],
            macAlgorithmsClientToServer: ["hmac-sha2-256"],
            macAlgorithmsServerToClient: ["hmac-sha2-256"],
            compressionAlgorithmsClientToServer: ["none"],
            compressionAlgorithmsServerToClient: ["none"],
            languagesClientToServer: [],
            languagesServerToClient: [],
            firstKexPacketFollows: false
        )
    }

    private func onlyInit(_ multi: SSHMultiMessage?) throws -> SSHMessage.KeyExchangeECDHInitMessage {
        guard let multi, multi.count == 1, case .keyExchangeInit(let message) = multi.first! else {
            XCTFail("expected one key exchange init, got \(String(describing: multi))")
            throw NIOSSHError.invalidPacketFormat
        }
        return message
    }

    private func mpintBody(_ value: SSHBigUInt) -> ByteBuffer {
        ByteBuffer(bytes: DiffieHellmanParameters.mpintBody(value))
    }

    func testGroupExchangeAgainstATestServer() throws {
        let recorder = Recorder()
        var client = self.clientMachine(recorder)
        let ourKexInit = client.createKeyExchangeMessage()
        client.send(keyExchange: ourKexInit)
        let serverKexInit = self.serverKexInit("diffie-hellman-group-exchange-sha256")

        // KEXINIT answered with SSH_MSG_KEX_DH_GEX_REQUEST (34): min 2048, n 3072, max 8192.
        let request = try self.onlyInit(client.handle(keyExchange: serverKexInit))
        XCTAssertEqual(request.kind, .groupExchangeRequest(minimum: 2048, preferred: 3072, maximum: 8192))
        XCTAssertEqual(request.messageID, 34)
        client.send(keyExchangeInit: request)
        XCTAssertEqual(recorder.negotiated.first?.keyExchange, "diffie-hellman-group-exchange-sha256")

        // The server picks group 14; the client answers with KEX_DH_GEX_INIT (32).
        let group = DiffieHellmanGroup.group14
        let groupMessage = SSHMessage.KeyExchangeDHGroupExchangeGroupMessage(
            prime: self.mpintBody(group.prime),
            generator: self.mpintBody(group.generator)
        )
        let gexInit = try self.onlyInit(client.handle(keyExchangeDHGroupExchangeGroup: groupMessage))
        XCTAssertEqual(gexInit.kind, .groupExchangeInit)
        XCTAssertEqual(gexInit.messageID, 32)
        client.send(keyExchangeInit: gexInit)

        // A second group is a protocol error.
        var again = client
        XCTAssertThrowsError(try again.handle(keyExchangeDHGroupExchangeGroup: groupMessage))

        // The test server: f = g^y, K = e^y, H per RFC 4419 section 3, signed with an Ed25519 key.
        let modulus = SSHMontgomeryModulus(group.prime)!
        let y = DiffieHellmanParameters.randomExponent()
        let e = SSHBigUInt(bigEndianBytes: gexInit.publicKey.readableBytesView)
        let f = modulus.power(group.generator, exponent: y, exponentBits: 512)
        let k = modulus.power(e, exponent: y, exponentBits: 512)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        var exchange = ByteBuffer()
        exchange.writeSSHString(Array(Constants.version.utf8))
        exchange.writeSSHString(Array("SSH-2.0-cryptlib".utf8))
        exchange.writeCompositeSSHString { $0.writeSSHMessage(.keyExchange(ourKexInit)) }
        exchange.writeCompositeSSHString { $0.writeSSHMessage(.keyExchange(serverKexInit)) }
        exchange.writeCompositeSSHString { $0.writeSSHHostKey(hostKey.publicKey) }
        exchange.writeMultipleIntegers(UInt32(2048), UInt32(3072), UInt32(8192))
        for value in [group.prime, group.generator, e, f, k] {
            exchange.writeBytes(SSHKeyDerivation.mpint(value.bigEndianBytes))
        }
        let h = SHA256.hash(data: exchange.readableBytesView)
        var reply = SSHMessage.KeyExchangeECDHReplyMessage(
            hostKey: hostKey.publicKey,
            publicKey: self.mpintBody(f),
            signature: try hostKey.sign(digest: h)
        )

        // A plain KEXDH_REPLY (31) is refused during a group exchange.
        var plain = client
        XCTAssertThrowsError(try plain.handle(keyExchangeReply: reply))

        reply.isGroupExchangeReply = true
        let future = try client.handle(keyExchangeReply: reply)
        XCTAssertNoThrow(try future.wait())
    }

    func testGroupExchangeRefusesSmallOrBadGroups() throws {
        func machineAfterRequest() throws -> SSHKeyExchangeStateMachine {
            var client = self.clientMachine(Recorder())
            client.send(keyExchange: client.createKeyExchangeMessage())
            let request = try self.onlyInit(
                client.handle(keyExchange: self.serverKexInit("diffie-hellman-group-exchange-sha1"))
            )
            client.send(keyExchangeInit: request)
            return client
        }
        let g2 = self.mpintBody(SSHBigUInt(limbs: [2]))
        // 1024 bit group (below the 2048 minimum), an even "prime", g = 1, g = p - 1.
        let p1024 = self.mpintBody(DiffieHellmanGroup.group1.prime)
        let even = self.mpintBody(DiffieHellmanGroup.group14.prime.subtracting(SSHBigUInt(limbs: [1])))
        let p = DiffieHellmanGroup.group14.prime
        for (prime, generator) in [
            (p1024, g2), (even, g2), (self.mpintBody(p), self.mpintBody(SSHBigUInt(limbs: [1]))),
            (self.mpintBody(p), self.mpintBody(p.subtracting(SSHBigUInt(limbs: [1])))),
        ] {
            var client = try machineAfterRequest()
            XCTAssertThrowsError(
                try client.handle(keyExchangeDHGroupExchangeGroup: .init(prime: prime, generator: generator))
            )
        }
    }

    func testServerValueOutOfRangeIsRefused() throws {
        for bad in [SSHBigUInt(limbs: [1]), DiffieHellmanGroup.group14.prime.subtracting(SSHBigUInt(limbs: [1]))] {
            var client = self.clientMachine(Recorder())
            client.send(keyExchange: client.createKeyExchangeMessage())
            let initMessage = try self.onlyInit(
                client.handle(keyExchange: self.serverKexInit("diffie-hellman-group14-sha256"))
            )
            client.send(keyExchangeInit: initMessage)
            let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
            let reply = SSHMessage.KeyExchangeECDHReplyMessage(
                hostKey: hostKey.publicKey,
                publicKey: self.mpintBody(bad),
                signature: try hostKey.sign(digest: SHA256.hash(data: [1]))
            )
            XCTAssertThrowsError(try client.handle(keyExchangeReply: reply))
        }
    }

    func testSignatureAlgorithmMustMatchTheNegotiatedHostKeyAlgorithm() throws {
        // The server offers rsa-sha2-256 but signs with Ed25519: refused before any key is used.
        var client = self.clientMachine(Recorder())
        client.send(keyExchange: client.createKeyExchangeMessage())
        var kexInit = self.serverKexInit("diffie-hellman-group14-sha256")
        kexInit.serverHostKeyAlgorithms = ["rsa-sha2-256"]
        let initMessage = try self.onlyInit(client.handle(keyExchange: kexInit))
        client.send(keyExchangeInit: initMessage)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let reply = SSHMessage.KeyExchangeECDHReplyMessage(
            hostKey: hostKey.publicKey,
            publicKey: self.mpintBody(SSHBigUInt(limbs: [5])),
            signature: try hostKey.sign(digest: SHA256.hash(data: [1]))
        )
        XCTAssertThrowsError(try client.handle(keyExchangeReply: reply)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .invalidHostKeyForKeyExchange)
        }
    }
}
