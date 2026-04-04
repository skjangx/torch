import AppKit
import Foundation
import StackAuth
#if canImport(Security)
import Security
#endif

enum AuthManagerError: LocalizedError {
    case invalidCallback
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return String(
                localized: "settings.account.error.invalidCallback",
                defaultValue: "The sign-in callback was invalid."
            )
        case .missingAccessToken:
            return String(
                localized: "settings.account.error.missingAccessToken",
                defaultValue: "Account access token is unavailable."
            )
        }
    }
}

protocol StackAuthTokenStoreProtocol: TokenStoreProtocol, Sendable {
    func seed(accessToken: String, refreshToken: String) async
    func clear() async
    func currentAccessToken() async -> String?
    func currentRefreshToken() async -> String?
}

extension StackAuthTokenStoreProtocol {
    func seed(accessToken: String, refreshToken: String) async {
        await setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    func clear() async {
        await clearTokens()
    }

    func currentAccessToken() async -> String? {
        await getStoredAccessToken()
    }

    func currentRefreshToken() async -> String? {
        await getStoredRefreshToken()
    }
}

protocol AuthClientProtocol: Sendable {
    func currentUser() async throws -> CMUXAuthUser?
    func listTeams() async throws -> [AuthTeamSummary]
    func currentAccessToken() async throws -> String?
    func signOut() async throws
}

extension AuthClientProtocol {
    func currentAccessToken() async throws -> String? { nil }
    func signOut() async throws {}
}

enum AuthKeychainServiceName {
    static let stableFallback = "com.cmuxterm.app.auth"

    static func make(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return stableFallback
        }
        return "\(bundleIdentifier).auth"
    }
}

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: CMUXAuthUser?
    @Published private(set) var availableTeams: [AuthTeamSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRestoringSession = false
    @Published private(set) var didCompleteBrowserSignIn = false
    @Published var selectedTeamID: String? {
        didSet {
            guard selectedTeamID != oldValue else { return }
            settingsStore.selectedTeamID = selectedTeamID
        }
    }

    var resolvedTeamID: String? {
        Self.resolveTeamID(selectedTeamID: selectedTeamID, teams: availableTeams)
    }

    let requiresAuthenticationGate = false

    private let client: any AuthClientProtocol
    private let tokenStore: any StackAuthTokenStoreProtocol
    private let settingsStore: AuthSettingsStore
    private let urlOpener: (URL) -> Void

    init(
        client: (any AuthClientProtocol)? = nil,
        tokenStore: any StackAuthTokenStoreProtocol = KeychainStackTokenStore(),
        settingsStore: AuthSettingsStore = AuthSettingsStore(),
        urlOpener: ((URL) -> Void)? = nil
    ) {
        self.tokenStore = tokenStore
        self.settingsStore = settingsStore
        self.client = client ?? Self.makeDefaultClient(tokenStore: tokenStore)
        self.urlOpener = urlOpener ?? Self.defaultURLOpener
        self.currentUser = settingsStore.cachedUser()
        self.selectedTeamID = settingsStore.selectedTeamID
        self.isAuthenticated = self.currentUser != nil
        Task { [weak self] in
            await self?.restoreStoredSessionIfNeeded()
        }
    }

    func beginSignInInBrowser() {
        urlOpener(AuthEnvironment.signInURL())
    }

    func handleCallbackURL(_ url: URL) async throws {
        guard let payload = AuthCallbackRouter.callbackPayload(from: url) else {
            throw AuthManagerError.invalidCallback
        }

        isLoading = true
        defer { isLoading = false }

        await tokenStore.seed(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken
        )
        try await refreshSession()
        didCompleteBrowserSignIn = true
    }

    func signOut() async {
        try? await client.signOut()
        await tokenStore.clear()
        clearSessionState(clearSelectedTeam: true)
    }

    func getAccessToken() async throws -> String {
        if let accessToken = try await client.currentAccessToken(),
           !accessToken.isEmpty {
            return accessToken
        }
        if let cached = await tokenStore.currentAccessToken(),
           !cached.isEmpty {
            return cached
        }
        throw AuthManagerError.missingAccessToken
    }

    private func restoreStoredSessionIfNeeded() async {
        let hasAccessToken = await tokenStore.currentAccessToken() != nil
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        let hasTokens = hasAccessToken || hasRefreshToken
        guard hasTokens else {
            clearSessionState(clearSelectedTeam: true)
            return
        }

        isAuthenticated = currentUser != nil
        isRestoringSession = true
        defer { isRestoringSession = false }

        do {
            try await refreshSession()
        } catch {
            if currentUser == nil {
                isAuthenticated = false
            }
        }
    }

    private func refreshSession() async throws {
        let user = try await client.currentUser()
        let teams = try await client.listTeams()
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        currentUser = user
        settingsStore.saveCachedUser(user)
        availableTeams = teams
        isAuthenticated = user != nil || hasRefreshToken
        selectedTeamID = Self.resolveTeamID(selectedTeamID: selectedTeamID, teams: teams)
    }

    private func clearSessionState(clearSelectedTeam: Bool) {
        availableTeams = []
        currentUser = nil
        isAuthenticated = false
        didCompleteBrowserSignIn = false
        if clearSelectedTeam {
            selectedTeamID = nil
        }
        settingsStore.saveCachedUser(nil)
    }

    private static func makeDefaultClient(
        tokenStore: any StackAuthTokenStoreProtocol
    ) -> any AuthClientProtocol {
        UITestAuthClient.makeIfEnabled(tokenStore: tokenStore) ?? LiveAuthClient(tokenStore: tokenStore)
    }

    private static func defaultURLOpener(_ url: URL) {
        let environment = ProcessInfo.processInfo.environment
        if let capturePath = environment["CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !capturePath.isEmpty {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: capturePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? url.absoluteString.write(
                to: URL(fileURLWithPath: capturePath),
                atomically: true,
                encoding: .utf8
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func resolveTeamID(
        selectedTeamID: String?,
        teams: [AuthTeamSummary]
    ) -> String? {
        if let selectedTeamID,
           teams.contains(where: { $0.id == selectedTeamID }) {
            return selectedTeamID
        }
        return teams.first?.id
    }
}

extension AuthManager: MachineSessionAuthProvider {}

private actor KeychainStackTokenStore: StackAuthTokenStoreProtocol {
    private static let accessTokenAccount = "cmux-auth-access-token"
    private static let refreshTokenAccount = "cmux-auth-refresh-token"
    private let service = AuthKeychainServiceName.make()

    func getStoredAccessToken() async -> String? {
        keychainValue(account: Self.accessTokenAccount)
    }

    func getStoredRefreshToken() async -> String? {
        keychainValue(account: Self.refreshTokenAccount)
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        if let accessToken {
            setKeychainValue(accessToken, account: Self.accessTokenAccount)
        } else {
            deleteKeychainValue(account: Self.accessTokenAccount)
        }

        if let refreshToken {
            setKeychainValue(refreshToken, account: Self.refreshTokenAccount)
        } else {
            deleteKeychainValue(account: Self.refreshTokenAccount)
        }
    }

    func clearTokens() async {
        deleteKeychainValue(account: Self.accessTokenAccount)
        deleteKeychainValue(account: Self.refreshTokenAccount)
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        guard keychainValue(account: Self.refreshTokenAccount) == compareRefreshToken else {
            return
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

    private func keychainValue(account: String) -> String? {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    private func setKeychainValue(_ value: String, account: String) {
#if canImport(Security)
        guard let data = value.data(using: .utf8) else { return }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = lookup
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
#endif
    }

    private func deleteKeychainValue(account: String) {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
#endif
    }
}

actor LiveAuthClient: AuthClientProtocol {
    private let stack: StackClientApp

    init(
        tokenStore: any StackAuthTokenStoreProtocol
    ) {
        self.stack = StackClientApp(
            projectId: AuthEnvironment.stackProjectID,
            publishableClientKey: AuthEnvironment.stackPublishableClientKey,
            baseUrl: AuthEnvironment.stackBaseURL.absoluteString,
            tokenStore: .custom(tokenStore),
            noAutomaticPrefetch: true
        )
    }

    func currentAccessToken() async throws -> String? {
        await stack.getAccessToken()
    }

    func currentUser() async throws -> CMUXAuthUser? {
        guard let payload = try await stack.getUser() else { return nil }
        return CMUXAuthUser(
            id: await payload.id,
            primaryEmail: await payload.primaryEmail,
            displayName: await payload.displayName
        )
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        guard let user = try await stack.getUser() else {
            return []
        }

        let teams = try await user.listTeams()
        var summaries: [AuthTeamSummary] = []
        summaries.reserveCapacity(teams.count)
        for team in teams {
            summaries.append(
                AuthTeamSummary(
                    id: team.id,
                    displayName: await team.displayName
                )
            )
        }
        return summaries
    }

    func signOut() async throws {
        try await stack.signOut()
    }
}

private struct UITestAuthClient: AuthClientProtocol {
    let tokenStore: any StackAuthTokenStoreProtocol
    let user: CMUXAuthUser
    let teams: [AuthTeamSummary]

    static func makeIfEnabled(
        tokenStore: any StackAuthTokenStoreProtocol
    ) -> Self? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_UI_TEST_AUTH_STUB"] == "1" else {
            return nil
        }

        let user = CMUXAuthUser(
            id: environment["CMUX_UI_TEST_AUTH_USER_ID"] ?? "ui_test_user",
            primaryEmail: environment["CMUX_UI_TEST_AUTH_EMAIL"] ?? "uitest@cmux.dev",
            displayName: environment["CMUX_UI_TEST_AUTH_NAME"] ?? "UI Test"
        )
        let teams = [
            AuthTeamSummary(
                id: environment["CMUX_UI_TEST_AUTH_TEAM_ID"] ?? "team_alpha",
                displayName: environment["CMUX_UI_TEST_AUTH_TEAM_NAME"] ?? "Alpha"
            ),
        ]
        return Self(tokenStore: tokenStore, user: user, teams: teams)
    }

    func currentUser() async throws -> CMUXAuthUser? {
        let hasAccessToken = await tokenStore.currentAccessToken() != nil
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        return (hasAccessToken || hasRefreshToken) ? user : nil
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        let hasAccessToken = await tokenStore.currentAccessToken() != nil
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        return (hasAccessToken || hasRefreshToken) ? teams : []
    }

    func currentAccessToken() async throws -> String? {
        await tokenStore.currentAccessToken()
    }
}
