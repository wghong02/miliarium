# Miliarium — Test Coverage

What the automated tests cover, mapped to `FUNCTIONALITY.md`. All current
coverage lives in the **`miliariumUITests`** target (black-box UI/integration
tests driven through `XCUIApplication`). There is no unit-test target — see
"Why no unit tests" at the bottom.

## How the tests run

- **Real Firebase Auth, no mocks** — tests need network connectivity and the
  shared test account.
- **`miliariumUITests/TestSecrets.json`** (git-ignored) must exist — copy
  `miliariumUITests/TestSecrets.example.json` and fill in a throwaway Firebase
  account. Without it, auth-dependent tests **skip** (they don't fail).
- Every test launches with the `-uitest-reset-auth` argument, which the app
  honours in `AuthViewModel.init` by signing out at startup — so each test
  begins from a clean, signed-out state regardless of run order.
- Run **serially** (Scheme → Test → Options → uncheck "Execute in parallel")
  on an **iPhone simulator in portrait**. Parallel runs / landscape are the
  main sources of flakiness.

## Support code — `UITestSupport.swift`

Not tests; shared helpers used by the suites.

| Symbol | Purpose |
|---|---|
| `TestAccount.credentials` | Loads `TestSecrets.json` from the test bundle at runtime; `nil` if absent. |
| `requireTestCredentials()` | Returns credentials or throws `XCTSkip` when `TestSecrets.json` is missing. |
| `XCUIApplication.launchForUITesting()` | Launches with `-uitest-reset-auth` (deterministic signed-out start). |
| `XCUIApplication.waitForTabBar()` | Waits for the authenticated tab bar to appear. |
| `XCUIApplication.signIn(with:)` | Signs in from the login screen and asserts the tab bar appears; hardened against the "no keyboard focus" flake. |

---

## `AuthUITests` — Authentication (§1)

Each test launches signed-out via `-uitest-reset-auth`. The submit button is
queried by its accessibility identifier `authSubmitButton` (its visible title
collides with the mode segmented control).

| Test | What it verifies |
|---|---|
| `testLoginFormShowsEmailPasswordAndAction` | On the login screen the Email field, Password field, and submit button are all present (§1.1). |
| `testSubmitDisabledWhenBothFieldsEmpty` | Submit is disabled when both fields are empty. |
| `testSubmitDisabledWithOnlyEmail` | Submit stays disabled with only the email filled (password still empty). |
| `testSubmitEnablesWhenBothFieldsFilled` | Submit enables once both email and password are non-empty. |
| `testModeSwitchChangesSubmitTitle` | Tapping the "Create account" segment relabels the action button from "Sign in" to "Create account". |
| `testSignInWithValidCredentialsEntersApp` | Valid credentials move the user into the main tab view (five tabs appear). **Needs `TestSecrets.json` + network.** |
| `testSignInWithInvalidCredentialsShowsInlineError` | A wrong password surfaces the inline red error row (`authErrorMessage`), the tab bar does **not** appear, and the login screen remains. **Needs `TestSecrets.json` + network.** |
| `testSignOutReturnsToLoginForm` | After signing in, Profile → "Sign out" (scrolled into view if off-screen) returns to the "Welcome" login screen and removes the tab bar (§1.2). **Needs `TestSecrets.json` + network.** |

---

## `HomeUITests` — Home tab (§3)

`setUp` launches clean then signs in with the test account, so every test runs
against a real authenticated session. If `TestSecrets.json` is missing, the
whole suite skips.

| Test | What it verifies |
|---|---|
| `testTabBarHasFiveTabs` | The tab bar exposes all five tabs: Home, Calendar, Map, Activity, Profile. |
| `testHomeShowsProgressMenu` | The Home tab always shows the top-left progress menu (accessibility label "Choose progress") (§3.2 / §3.6). |
| `testHomeShowsEitherEmptyStateOrContent` | Home shows exactly one of: the "No progress yet" empty state, or selected-progress content (the "Add activity" toolbar button) — never both (§3.6). |
| `testAddActivityButtonVisibilityMatchesSelection` | The top-right "Add activity" button is hidden in the empty state and visible when a progress is selected (§3.6 / §5.1). |

### Intentional skipped stubs

These `XCTSkip` on purpose (they show as *skipped*, not failed) — documented
placeholders for flows that need extra setup:

| Test | Why it's a stub |
|---|---|
| `testCreateProgressFlow` | Would create a progress; needs self-cleanup (delete what it created) to avoid polluting the shared test account. |
| `testDeleteProgressIsOwnerOnly` | Needs a second collaborator account to assert the negative case (collaborators don't see "Delete Progress") (§3.5 / §9.1). |

---

## Coverage gaps (not yet tested)

Sections of `FUNCTIONALITY.md` with no automated coverage yet: §2 Profile,
§4 Collections, §5 Activities (beyond the add-button visibility check),
§6 Calendar, §7 Map, §8 Invitations, §9 Roles, §10 Navigation,
§11 Input validation, §12 Widgets, §13 Onboarding.

## Why no unit tests

A `@testable import miliarium` unit-test target proved not worth it: the app
module transitively links Firebase's C++ stack (gRPC / Abseil / Firestore),
and getting a second target to link that cleanly is whack-a-mole (undefined
`absl::lts_*` symbols). If unit tests are revived, do it by extracting the
pure-logic types into a **local, Firebase-free Swift Package** that both the
app and tests depend on — do not `@testable import` the Firebase-heavy app
module.

## Environment note

Simulator "Resource temporarily unavailable" / "failed to launch the test
runner" errors are environmental (a wedged simulator), not test failures —
reset with `xcrun simctl shutdown all && xcrun simctl erase all`.
