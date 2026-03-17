# cmuxterm Optional Sign-In Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional account sign-in flow to the Swift macOS cmux app so a signed-in Mac can publish itself and its workspaces for iOS dogfooding, while unsigned local terminal use remains unchanged.

**Architecture:** Reuse the existing iOS auth shape instead of inventing a second auth system. The macOS app gets a small shared auth-core package, a native `AuthManager`, a settings-hosted sign-in sheet, and a background publisher that uses the existing mobile machine-session and heartbeat routes. Signed-out state must be a no-op for cloud features, not an app gate.

**Tech Stack:** SwiftUI, AppKit, StackAuth, URLSession, local Swift package (`CMUXAuthCore`), Hono, Convex team membership queries, Tailscale CLI discovery.

**Scope Note:** This plan covers optional sign-in, team selection, and machine/workspace presence publishing. It does **not** add Electron-style zero-config direct terminal attach from a brand-new Mac. That direct-daemon publisher is a separate runtime project and should stay out of this auth-first plan.

---

## Chunk 1: Freeze The Missing Product Contract

### File Structure

**cmux repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in`

- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`
- Modify: `Package.resolved`
- Modify: `Resources/Localizable.xcstrings`
- Modify: `Sources/cmuxApp.swift`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/TabManager.swift`
- Modify: `Sources/Workspace.swift`
- Create: `Packages/CMUXAuthCore/Package.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthConfig.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthIdentityStore.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthSessionCache.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthState.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthUser.swift`
- Create: `Packages/CMUXAuthCore/Tests/CMUXAuthCoreTests/CMUXAuthStateTests.swift`
- Create: `Sources/Auth/AuthEnvironment.swift`
- Create: `Sources/Auth/StackAuthApp.swift`
- Create: `Sources/Auth/AuthManager.swift`
- Create: `Sources/Auth/AuthSettingsStore.swift`
- Create: `Sources/Auth/SignInSheetView.swift`
- Create: `Sources/MobilePresence/MobileBootstrapClient.swift`
- Create: `Sources/MobilePresence/MobileMachineIdentityService.swift`
- Create: `Sources/MobilePresence/WorkspaceSnapshotBuilder.swift`
- Create: `Sources/MobilePresence/MobileHeartbeatPublisher.swift`
- Test: `cmuxTests/AuthManagerTests.swift`
- Test: `cmuxTests/MobileBootstrapClientTests.swift`
- Test: `cmuxTests/WorkspaceSnapshotBuilderTests.swift`
- Test: `cmuxTests/MobileHeartbeatPublisherTests.swift`
- Test: `cmuxUITests/SettingsAccountUITests.swift`

**manaflow repo:** `/Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex`

- Modify: `apps/www/lib/routes/index.ts`
- Create: `apps/www/lib/routes/mobile-bootstrap.route.ts`
- Test: `apps/www/lib/routes/mobile-bootstrap.route.test.ts`

### Task 1: Write Down The Real Optional-Sign-In Contract

**Files:**
- Test: `Packages/CMUXAuthCore/Tests/CMUXAuthCoreTests/CMUXAuthStateTests.swift`
- Test: `cmuxTests/AuthManagerTests.swift`
- Test: `apps/www/lib/routes/mobile-bootstrap.route.test.ts`

- [ ] **Step 1: Add the failing auth-state package test**

```swift
func testPrimedSignedOutStateDoesNotGateLocalApp() {
    let state = CMUXAuthState.primed(
        clearAuthRequested: false,
        mockDataEnabled: false,
        fixtureUser: nil,
        autoLoginCredentials: nil,
        cachedUser: nil,
        hasTokens: false,
        mockUser: CMUXAuthUser(id: "mock", primaryEmail: nil, displayName: "Mock")
    )

    XCTAssertFalse(state.isAuthenticated)
    XCTAssertNil(state.currentUser)
    XCTAssertFalse(state.isRestoringSession)
}
```

- [ ] **Step 2: Add the failing mac auth-manager test**

```swift
func testSignedOutManagerLeavesCloudFeaturesDisabledButAppUsable() async throws {
    let manager = AuthManager(
        stack: FakeStackAuthClient(),
        userCache: InMemoryAuthUserCache(),
        sessionCache: InMemoryAuthSessionCache(),
        settingsStore: InMemoryAuthSettingsStore()
    )

    await manager.restoreSessionIfNeeded()

    XCTAssertFalse(manager.isAuthenticated)
    XCTAssertNil(manager.currentUser)
    XCTAssertNil(manager.selectedTeamID)
}
```

- [ ] **Step 3: Add the failing backend bootstrap-route test**

```ts
it("returns the signed-in user's teams for native clients", async () => {
  const app = createAppWithMobileBootstrapTestRouter({
    user: { id: "user_123", primaryEmail: "l@cmux.dev" },
    teams: [
      { teamId: "team_a", slug: "cmux", displayName: "cmux" },
      { teamId: "team_b", slug: "labs", displayName: "Labs" },
    ],
  });

  const response = await app.request("/mobile/bootstrap", {
    headers: { Authorization: "Bearer valid-token" },
  });

  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({
    userId: "user_123",
    email: "l@cmux.dev",
    teams: [
      { teamId: "team_a", slug: "cmux", displayName: "cmux" },
      { teamId: "team_b", slug: "labs", displayName: "Labs" },
    ],
    defaultTeamId: "team_a",
  });
});
```

- [ ] **Step 4: Run the focused tests and confirm they fail**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && swift test --package-path Packages/CMUXAuthCore
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-auth-contract -only-testing:cmuxTests/AuthManagerTests test
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex/apps/www && bunx vitest run lib/routes/mobile-bootstrap.route.test.ts
```

Expected:
- `swift test` fails because `CMUXAuthCore` does not exist in this repo yet.
- `xcodebuild` fails because `AuthManager` and the in-memory caches do not exist.
- `vitest` fails because `/mobile/bootstrap` does not exist.

- [ ] **Step 5: Commit the failing tests**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Packages/CMUXAuthCore/Tests/CMUXAuthCoreTests/CMUXAuthStateTests.swift cmuxTests/AuthManagerTests.swift
git commit -m "test: define optional sign-in contract"

cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
git add apps/www/lib/routes/mobile-bootstrap.route.test.ts
git commit -m "test: define mobile bootstrap route contract"
```

## Chunk 2: Add The Shared Auth And Bootstrap Foundation

### Task 2: Port The Shared Auth Core Into cmuxterm

**Files:**
- Create: `Packages/CMUXAuthCore/Package.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthConfig.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthIdentityStore.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthSessionCache.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthState.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthUser.swift`
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`
- Modify: `Package.resolved`
- Test: `Packages/CMUXAuthCore/Tests/CMUXAuthCoreTests/CMUXAuthStateTests.swift`

- [ ] **Step 1: Create the local package skeleton**

Add:

```swift
// Packages/CMUXAuthCore/Package.swift
let package = Package(
    name: "CMUXAuthCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CMUXAuthCore", targets: ["CMUXAuthCore"])],
    targets: [
        .target(name: "CMUXAuthCore"),
        .testTarget(name: "CMUXAuthCoreTests", dependencies: ["CMUXAuthCore"]),
    ]
)
```

- [ ] **Step 2: Copy the stable shared auth-core types from iOS**

Add the exact minimal types already proven in the iOS repo:
- `CMUXAuthConfig`
- `CMUXAuthUser`
- `CMUXAuthIdentityStore`
- `CMUXAuthSessionCache`
- `CMUXAuthState`

Do not add UI or network code to this package.

- [ ] **Step 3: Add the package to the Xcode project**

Wire `CMUXAuthCore` into the macOS app target through `GhosttyTabs.xcodeproj/project.pbxproj`.

Do not touch the root `Package.swift`. The app is built from the Xcode project, not the CLI package.

- [ ] **Step 4: Run the package test**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && swift test --package-path Packages/CMUXAuthCore
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Packages/CMUXAuthCore GhosttyTabs.xcodeproj/project.pbxproj Package.resolved
git commit -m "auth: add shared auth core package"
```

### Task 3: Add A Thin Auth Bootstrap Route For Native Clients

**Files:**
- Create: `apps/www/lib/routes/mobile-bootstrap.route.ts`
- Modify: `apps/www/lib/routes/index.ts`
- Test: `apps/www/lib/routes/mobile-bootstrap.route.test.ts`

- [ ] **Step 1: Implement the minimal authenticated response shape**

Return:

```ts
{
  userId: string;
  email: string | null;
  teams: Array<{
    teamId: string;
    slug: string | null;
    displayName: string | null;
  }>;
  defaultTeamId: string | null;
}
```

Implementation rules:
- authenticate with `getUserFromRequest`
- resolve memberships via the existing Convex team helpers, not ad hoc SQL or duplicated team logic
- default to the first team membership for dogfood
- return `401` when no valid Stack cookie or bearer token exists

- [ ] **Step 2: Export the route**

Add it to `apps/www/lib/routes/index.ts`.

- [ ] **Step 3: Run the backend test**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex/apps/www && bunx vitest run lib/routes/mobile-bootstrap.route.test.ts
```

Expected: PASS.

- [ ] **Step 4: Run repo typecheck**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && bunx tsc --noEmit -p apps/www/tsconfig.json
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
git add apps/www/lib/routes/mobile-bootstrap.route.ts apps/www/lib/routes/index.ts apps/www/lib/routes/mobile-bootstrap.route.test.ts
git commit -m "www: add native mobile bootstrap route"
```

## Chunk 3: Add Optional Sign-In To The Swift App

### Task 4: Add The Native Auth Manager Without Gating Local Use

**Files:**
- Create: `Sources/Auth/AuthEnvironment.swift`
- Create: `Sources/Auth/StackAuthApp.swift`
- Create: `Sources/Auth/AuthManager.swift`
- Create: `Sources/Auth/AuthSettingsStore.swift`
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`
- Modify: `Package.resolved`
- Test: `cmuxTests/AuthManagerTests.swift`

- [ ] **Step 1: Add the failing restore and sign-out tests**

Add tests for:

```swift
func testRestoreUsesCachedUserWhenTokensExist() async throws
func testSignOutClearsUserAndSelectedTeam() async throws
func testOptionalAuthDoesNotBlockSignedOutState() async throws
```

- [ ] **Step 2: Add the StackAuth dependency to the app target**

Add the remote package and link it in `GhosttyTabs.xcodeproj/project.pbxproj`.

The manager should use:

```swift
enum StackAuthApp {
    static let shared = StackClientApp(
        projectId: AuthEnvironment.current.stackAuthProjectId,
        publishableClientKey: AuthEnvironment.current.stackAuthPublishableKey,
        tokenStore: .keychain
    )
}
```

- [ ] **Step 3: Add the environment wrapper**

`AuthEnvironment.swift` should mirror the proven iOS constants pattern:

```swift
enum AuthEnvironment {
    case development
    case production

    var stackAuthProjectId: String { ... }
    var stackAuthPublishableKey: String { ... }
    var apiBaseURL: String { ... }
}
```

Use dev/prod constants and allow plist overrides later if needed. Do not hardcode secrets other than the publishable Stack key and public API origins.

- [ ] **Step 4: Implement `AuthManager`**

Requirements:
- restore cached user and session presence on launch
- expose `isAuthenticated`, `currentUser`, `selectedTeamID`, `availableTeams`, `isLoading`
- provide `sendCode(to:)`, `verifyCode(_:)`, `signOut()`, `refreshBootstrap()`
- clear team selection on sign-out if the previous team is no longer valid
- never gate the main cmux window when signed out

Use a small protocol boundary for StackAuth calls so `cmuxTests/AuthManagerTests.swift` can use a fake client.

- [ ] **Step 5: Run the focused tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-auth-manager -only-testing:cmuxTests/AuthManagerTests test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Sources/Auth GhosttyTabs.xcodeproj/project.pbxproj Package.resolved cmuxTests/AuthManagerTests.swift
git commit -m "auth: add optional mac sign-in state"
```

### Task 5: Add The Settings Account Section And Sign-In Sheet

**Files:**
- Create: `Sources/Auth/SignInSheetView.swift`
- Modify: `Sources/cmuxApp.swift`
- Modify: `Resources/Localizable.xcstrings`
- Test: `cmuxUITests/SettingsAccountUITests.swift`

- [ ] **Step 1: Add the failing UI test**

Add a UI test that checks both optionality and visibility:

```swift
func testSettingsShowsSignInButtonWhileSignedOut() throws
func testSignedOutLaunchStillShowsMainWorkspaceWindow() throws
```

The second test is important. It proves the sign-in feature did not turn cmux into an auth-gated app.

- [ ] **Step 2: Add the settings section**

In `SettingsView`, add an `Account` section with:
- current user email/name when signed in
- selected team picker when signed in and multiple teams exist
- `Sign In` button when signed out
- `Sign Out` button when signed in
- small explanatory text that cloud sync is optional and local terminal use continues signed out

All strings must use `String(localized:defaultValue:)` and be added to `Resources/Localizable.xcstrings`.

- [ ] **Step 3: Add the sign-in sheet**

Use a small native sheet with:
- email field
- “Email me a code” action
- 6-digit code field
- verify action

Use the same manager methods as iOS:

```swift
try await authManager.sendCode(to: email)
try await authManager.verifyCode(code)
```

Do not add Apple/Google sign-in in this plan.

- [ ] **Step 4: Run the safe local unit coverage**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-settings-auth build
```

Expected: PASS.

- [ ] **Step 5: Run the macOS UI test in CI**

Run:

```bash
gh workflow run test-e2e.yml --repo manaflow-ai/cmux -f ref=feat-cmuxterm-optional-sign-in -f test_filter="SettingsAccountUITests" -f record_video=true
```

Watch:

```bash
gh run list --repo manaflow-ai/cmux --workflow test-e2e.yml --limit 3
gh run watch --repo manaflow-ai/cmux <run-id>
```

Expected: PASS in GitHub Actions. Do not rely on local XCUITest runs.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Sources/cmuxApp.swift Sources/Auth/SignInSheetView.swift Resources/Localizable.xcstrings cmuxUITests/SettingsAccountUITests.swift
git commit -m "auth: add optional settings sign-in UI"
```

## Chunk 4: Publish Signed-In Machine Presence

### Task 6: Add Team Bootstrap And Selection Persistence

**Files:**
- Create: `Sources/MobilePresence/MobileBootstrapClient.swift`
- Create: `Sources/Auth/AuthSettingsStore.swift`
- Test: `cmuxTests/MobileBootstrapClientTests.swift`

- [ ] **Step 1: Add the failing bootstrap-client tests**

Add tests for:

```swift
func testBootstrapLoadsTeamsWithBearerToken() async throws
func testBootstrapDefaultsToFirstTeamWhenNoSelectionSaved() async throws
func testBootstrapPreservesSavedTeamWhenStillPresent() async throws
```

- [ ] **Step 2: Implement the bootstrap client**

Call:

```swift
GET /api/mobile/bootstrap
Authorization: Bearer <stack access token>
```

Decode:

```swift
struct MobileBootstrapResponse: Decodable {
    let userId: String
    let email: String?
    let teams: [MobileBootstrapTeam]
    let defaultTeamId: String?
}
```

- [ ] **Step 3: Persist selected team without coupling it to auth tokens**

`AuthSettingsStore` should store only:
- selected team ID
- maybe last successful bootstrap timestamp

Do not store access tokens yourself. Let StackAuth own token storage.

- [ ] **Step 4: Run the focused test**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-bootstrap-client -only-testing:cmuxTests/MobileBootstrapClientTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Sources/MobilePresence/MobileBootstrapClient.swift Sources/Auth/AuthSettingsStore.swift cmuxTests/MobileBootstrapClientTests.swift
git commit -m "auth: bootstrap mobile teams for mac sign-in"
```

### Task 7: Add Machine Identity And Heartbeat Publishing

**Files:**
- Create: `Sources/MobilePresence/MobileMachineIdentityService.swift`
- Create: `Sources/MobilePresence/WorkspaceSnapshotBuilder.swift`
- Create: `Sources/MobilePresence/MobileHeartbeatPublisher.swift`
- Modify: `Sources/TabManager.swift`
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/cmuxApp.swift`
- Test: `cmuxTests/WorkspaceSnapshotBuilderTests.swift`
- Test: `cmuxTests/MobileHeartbeatPublisherTests.swift`

- [ ] **Step 1: Add the failing snapshot-builder test**

```swift
func testBuildsWorkspaceRowsFromOpenLocalWorkspaces() throws {
    let manager = TabManager()
    let workspace = Workspace.testLocal(name: "MacBook / repo")

    manager.addWorkspaceForTesting(workspace)

    let rows = WorkspaceSnapshotBuilder().build(from: manager)
    XCTAssertEqual(rows.map(\.title), ["MacBook / repo"])
}
```

- [ ] **Step 2: Add the failing heartbeat-publisher test**

```swift
func testPublisherDoesNothingWhenSignedOut() async throws
func testPublisherRequestsMachineSessionAndPublishesHeartbeatWhenSignedIn() async throws
func testPublisherUsesTailscaleHostnameWhenAvailable() async throws
```

- [ ] **Step 3: Implement machine identity discovery**

`MobileMachineIdentityService` should resolve:
- stable `machineId` from a persisted UUID, not from `Host.current()`
- `displayName` from `Host.current().localizedName`
- `tailscaleHostname` and `tailscaleIPs` by running `tailscale status --json` best-effort

Rules:
- if Tailscale is unavailable, return empty IPs and `nil` hostname
- do not crash if the CLI is missing or returns malformed JSON

- [ ] **Step 4: Implement workspace snapshot building**

Extract only the minimum fields needed by `/api/mobile/heartbeat`:

```swift
struct MobileWorkspaceSnapshot: Encodable {
    let workspaceId: String
    let title: String
    let preview: String?
    let phase: String
    let tmuxSessionName: String
    let lastActivityAt: Int64
    let latestEventSeq: Int
    let lastEventAt: Int64?
}
```

Do not make the snapshot builder reach into UI-only state or view structs.

- [ ] **Step 5: Implement the publisher**

Behavior:
- idle when signed out or no team is selected
- fetch machine session from `/api/mobile/machine-session`
- publish to `/api/mobile/heartbeat`
- publish immediately on:
  - sign-in
  - team change
  - app launch
  - workspace list changes
  - app becoming active
- publish periodically with a real heartbeat timer, not sleeps

Signed-out behavior must remain:
- no network calls
- no app gating
- no alerts

- [ ] **Step 6: Run the focused tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-heartbeat -only-testing:cmuxTests/WorkspaceSnapshotBuilderTests -only-testing:cmuxTests/MobileHeartbeatPublisherTests test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Sources/MobilePresence Sources/TabManager.swift Sources/Workspace.swift Sources/AppDelegate.swift Sources/cmuxApp.swift cmuxTests/WorkspaceSnapshotBuilderTests.swift cmuxTests/MobileHeartbeatPublisherTests.swift
git commit -m "mobile: publish signed-in cmuxterm presence"
```

## Chunk 5: Dogfood Verification

### Task 8: Verify The Optional-Sign-In Dogfood Path

**Files:**
- Modify: `docs/superpowers/plans/2026-03-17-cmuxterm-optional-sign-in.md` (status note only, after verification)

- [ ] **Step 1: Run backend verification**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && bun check
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex/apps/www && bunx vitest run lib/routes/mobile-bootstrap.route.test.ts lib/routes/mobile-machine-session.route.test.ts lib/routes/mobile-heartbeat.route.test.ts
```

Expected: PASS.

- [ ] **Step 2: Run mac package and unit verification**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && swift test --package-path Packages/CMUXAuthCore
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-optional-auth-unit test
```

Expected: PASS.

- [ ] **Step 3: Run the macOS UI test in CI**

Run:

```bash
gh workflow run test-e2e.yml --repo manaflow-ai/cmux -f ref=feat-cmuxterm-optional-sign-in -f test_filter="SettingsAccountUITests" -f record_video=true
```

Expected: PASS in GitHub Actions.

- [ ] **Step 4: Build and reload a tagged dogfood app**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && ./scripts/reload.sh --tag optional-sign-in
```

Expected: tagged `cmux DEV optional-sign-in.app` launches successfully.

- [ ] **Step 5: Run the manual dogfood checklist**

Checklist:
- launch signed out and confirm normal local workspaces still work
- open Settings and confirm the new `Account` section shows a `Sign In` button
- complete email-code sign-in
- confirm current user and selected team appear in Settings
- confirm sign-out returns the app to signed-out state without hiding workspaces
- confirm the signed-in Mac appears at the top of the iOS `Terminals` screen within one heartbeat cycle
- confirm opening and closing a local workspace updates the iOS workspace list without duplicates
- confirm disabling Tailscale does not crash cmuxterm and just removes Tailscale metadata from publishes

- [ ] **Step 6: Record what is still out of scope**

If dogfood feedback now demands zero-config terminal attach from the newly signed-in Mac, write a second plan for:
- native direct-daemon publisher
- ticket-secret management
- TLS pin generation
- iOS direct attach without manual host setup

- [ ] **Step 7: Commit any final dogfood-only fixes**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add <files>
git commit -m "auth: finish optional mac sign-in dogfood flow"
```

## Notes

- The original `2026-03-16-ios-dogfood-convex-sqlite-tailscale.md` plan did **not** include any cmuxterm Swift app auth or heartbeat-publisher work. That omission is the reason the dogfood flow ended up relying on Electron as the first signed-in desktop surface.
- Keep sign-in optional. Do not add a launch gate, blocking overlay, or required account step to the main cmux window.
- Do not add Apple/Google sign-in in this plan. Email-code auth is enough to validate the dogfood loop.
- Do not use `sleep`, `usleep`, `Task.sleep`, or `DispatchQueue.asyncAfter` as auth/bootstrap timing crutches in runtime code. Use real callbacks, state changes, and notifications.
