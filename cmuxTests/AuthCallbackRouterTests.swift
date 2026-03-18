import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AuthCallbackRouterTests: XCTestCase {
    func testCallbackPayloadParsesStackTokensFromReleaseScheme() throws {
        let url = try XCTUnwrap(
            URL(
                string: "cmux://auth-callback?stack_refresh=refresh-token&stack_access=%5B%22refresh-token%22,%22access-token%22%5D"
            )
        )

        let payload = try XCTUnwrap(AuthCallbackRouter.callbackPayload(from: url))
        XCTAssertEqual(payload.refreshToken, "refresh-token")
        XCTAssertEqual(payload.accessToken, "access-token")
    }

    func testCallbackPayloadParsesTaggedDebugScheme() throws {
        let url = try XCTUnwrap(
            URL(
                string: "cmux-dev-auth-mobile://auth-callback?stack_refresh=refresh-two&stack_access=%5B%22refresh-two%22,%22access-two%22%5D"
            )
        )

        let payload = try XCTUnwrap(AuthCallbackRouter.callbackPayload(from: url))
        XCTAssertEqual(payload.refreshToken, "refresh-two")
        XCTAssertEqual(payload.accessToken, "access-two")
    }

    func testCallbackPayloadRejectsMissingTokens() throws {
        let url = try XCTUnwrap(URL(string: "cmux://auth-callback"))

        XCTAssertNil(AuthCallbackRouter.callbackPayload(from: url))
    }
}
