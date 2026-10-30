// AnsiView patch (see PATCHES.md): review findings I1 and I2 on keyboard-interactive answer
// lifetimes (a late answer must be dropped, not trap; a second question while one is unanswered
// is a protocol error).

import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSH

final class KeyboardInteractiveReviewTests: XCTestCase {
    final class Client: NIOSSHClientUserAuthenticationDelegate, NIOSSHClientKeyboardInteractiveDelegate {
        var pending: [EventLoopPromise<[String]>] = []
        func respond(to request: NIOSSHKeyboardInteractiveRequest, responsePromise: EventLoopPromise<[String]>) {
            self.pending.append(responsePromise)
        }
        func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            if availableMethods == [.password] {
                nextChallengePromise.succeed(.init(username: "u", serviceName: "", offer: .password(.init(password: "p"))))
            } else {
                nextChallengePromise.succeed(.init(username: "u", serviceName: "", offer: .keyboardInteractive))
            }
        }
    }

    let prompt = SSHMessage.UserAuthInfoRequestMessage(
        name: "", instruction: "", languageTag: "", prompts: [.init(prompt: "Password: ", echo: false)]
    )

    private func started(_ client: Client, _ loop: EmbeddedEventLoop) throws -> UserAuthenticationStateMachine {
        var machine = UserAuthenticationStateMachine(
            role: .client(.init(userAuthDelegate: client, serverAuthDelegate: AcceptAllHostKeysDelegate())),
            loop: loop,
            sessionID: ByteBuffer()
        )
        machine.sendServiceRequest(machine.beginAuthentication()!)
        let first = try machine.receiveServiceAccept(.init(service: "ssh-userauth"))!
        loop.run()
        machine.sendUserAuthRequest(try first.wait()!)
        return machine
    }

    func testAnswerInTimeIsSent() throws {
        let loop = EmbeddedEventLoop()
        let client = Client()
        var machine = try self.started(client, loop)
        let answer = try machine.receiveUserAuthInfoRequest(self.prompt)
        client.pending[0].succeed(["secret"])
        loop.run()
        XCTAssertTrue(machine.sendUserAuthInfoResponse(try answer.wait()))
    }

    func testLateAnswerAfterFailureIsDropped() throws {
        let loop = EmbeddedEventLoop()
        let client = Client()
        var machine = try self.started(client, loop)
        let answer = try machine.receiveUserAuthInfoRequest(self.prompt)
        // The server gives up on keyboard-interactive while the question is still open.
        let next = try machine.receiveUserAuthFailure(.init(authentications: ["password"], partialSuccess: false))!
        loop.run()
        machine.sendUserAuthRequest(try next.wait()!)
        client.pending[0].succeed(["late"])
        loop.run()
        XCTAssertFalse(machine.sendUserAuthInfoResponse(try answer.wait()))
    }

    func testLateAnswerAfterANewRoundIsDropped() throws {
        let loop = EmbeddedEventLoop()
        let client = Client()
        var machine = try self.started(client, loop)
        let first = try machine.receiveUserAuthInfoRequest(self.prompt)
        let next = try machine.receiveUserAuthFailure(.init(authentications: ["keyboard-interactive"], partialSuccess: false))!
        loop.run()
        machine.sendUserAuthRequest(try next.wait()!)
        let second = try machine.receiveUserAuthInfoRequest(self.prompt)
        client.pending[0].succeed(["old"])
        client.pending[1].succeed(["new"])
        loop.run()
        XCTAssertFalse(machine.sendUserAuthInfoResponse(try first.wait()))
        XCTAssertTrue(machine.sendUserAuthInfoResponse(try second.wait()))
    }

    func testSecondQuestionWhileTheFirstIsOpenIsRefused() throws {
        let loop = EmbeddedEventLoop()
        let client = Client()
        var machine = try self.started(client, loop)
        _ = try machine.receiveUserAuthInfoRequest(self.prompt)
        XCTAssertThrowsError(try machine.receiveUserAuthInfoRequest(self.prompt))
        client.pending[0].fail(ChannelError.eof)
    }

    func testPasswordChangeOnlyAfterAPasswordRequest() throws {
        let loop = EmbeddedEventLoop()
        let client = Client()
        let machine = try self.started(client, loop)
        // A keyboard-interactive request is in flight, not a password one.
        XCTAssertThrowsError(try machine.receiveUserAuthPasswordChangeRequest(.init(prompt: "x", languageTag: ""))) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }
}
