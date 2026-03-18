import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AuthManagerTests: XCTestCase {
    func testSignedOutStateDoesNotGateLocalApp() {
        let manager = AuthManager(
            client: StubAuthClient(user: nil, teams: []),
            tokenStore: StubStackTokenStore(),
            settingsStore: AuthSettingsStore(userDefaults: UserDefaults(suiteName: "AuthManagerTests.signedOut.\(UUID().uuidString)")!)
        )

        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertFalse(manager.requiresAuthenticationGate)
    }

    func testHandleCallbackSeedsTokensAndDefaultsToFirstTeamMembership() async throws {
        let tokenStore = StubStackTokenStore()
        let manager = AuthManager(
            client: StubAuthClient(
                user: CMUXAuthUser(id: "user_123", primaryEmail: "lawrence@cmux.dev", displayName: "Lawrence"),
                teams: [
                    AuthTeamSummary(id: "team_alpha", displayName: "Alpha"),
                    AuthTeamSummary(id: "team_beta", displayName: "Beta"),
                ]
            ),
            tokenStore: tokenStore,
            settingsStore: AuthSettingsStore(userDefaults: UserDefaults(suiteName: "AuthManagerTests.callback.\(UUID().uuidString)")!)
        )

        let callbackURL = try XCTUnwrap(
            URL(
                string: "cmux://auth-callback?stack_refresh=refresh-123&stack_access=%5B%22refresh-123%22,%22access-456%22%5D"
            )
        )

        try await manager.handleCallbackURL(callbackURL)

        XCTAssertEqual(await tokenStore.currentRefreshToken(), "refresh-123")
        XCTAssertEqual(await tokenStore.currentAccessToken(), "access-456")
        XCTAssertEqual(manager.selectedTeamID, "team_alpha")
    }
}

private actor StubStackTokenStore: StackAuthTokenStoreProtocol {
    private(set) var accessToken: String?
    private(set) var refreshToken: String?

    func seed(accessToken: String, refreshToken: String) async {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func clear() async {
        accessToken = nil
        refreshToken = nil
    }

    func currentAccessToken() -> String? {
        accessToken
    }

    func currentRefreshToken() -> String? {
        refreshToken
    }
}

private struct StubAuthClient: AuthClientProtocol {
    let user: CMUXAuthUser?
    let teams: [AuthTeamSummary]

    func currentUser() async throws -> CMUXAuthUser? {
        user
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        teams
    }
}
