import XCTest

/// UI tests for the Home tab (FUNCTIONALITY.md §3).
///
/// The app gates all tabs behind Firebase auth, and this suite runs without
/// a mocked auth layer or a seeded Firestore. So the tests split into two
/// tiers:
///
/// 1. **State-agnostic** — assertions that hold whether or not a session is
///    restored (app launches, reaches a known first screen, tab bar shape).
/// 2. **Authenticated-only** — Home-specific assertions guarded by
///    `isSignedIn`. When no session is present they `XCTSkip`, so they read
///    as skipped rather than failing in CI.
///
/// Flows that mutate data (create / delete progress) are left as documented
/// skipped stubs — they need a seeded test account or a launch-argument
/// auth bypass to run deterministically. Wire that up (e.g. honor the
/// `-uitesting` launch argument in the app to inject a fake auth state)
/// and the stubs can be filled in.
final class HomeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A hook the app can honor later to reset onboarding / inject a
        // deterministic auth state for UI testing. Harmless if ignored.
        app.launchArguments += ["-uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// True when a tab bar is present, i.e. the user is past the login gate.
    private var isSignedIn: Bool {
        app.tabBars.firstMatch.waitForExistence(timeout: 10)
    }

    /// Brings the Home tab to the front. Precondition: signed in.
    private func goToHome() {
        let homeTab = app.tabBars.buttons["Home"]
        if homeTab.exists { homeTab.tap() }
    }

    private func skipUnlessSignedIn() throws {
        try XCTSkipUnless(
            isSignedIn,
            "No authenticated session — Home-specific UI assertions require a signed-in state."
        )
    }

    // MARK: - Tier 1: state-agnostic

    func testAppLaunchesToKnownFirstScreen() {
        // Either the login screen ("Welcome") or the authed tab bar must
        // appear promptly. Anything else means a launch hang / crash.
        let welcome = app.navigationBars["Welcome"]
        let tabBar = app.tabBars.firstMatch
        let reachedKnownState = welcome.waitForExistence(timeout: 10)
            || tabBar.waitForExistence(timeout: 10)
        XCTAssertTrue(reachedKnownState, "App did not reach login or tab bar within 10s")
    }

    func testLoginScreenShapeWhenSignedOut() throws {
        try XCTSkipIf(isSignedIn, "Session restored — login screen not shown.")
        XCTAssertTrue(app.navigationBars["Welcome"].exists)
        XCTAssertTrue(app.textFields["Email"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        // Note: the action button and the mode segmented control both carry
        // the text "Sign in", so `buttons["Sign in"]` is ambiguous. A stable
        // accessibilityIdentifier on the action button would let us assert
        // its disabled-until-filled state directly; until then we only
        // assert the form's structural presence.
    }

    // MARK: - Tier 2: authenticated-only

    func testTabBarHasFiveTabs() throws {
        try skipUnlessSignedIn()
        for label in ["Home", "Calendar", "Map", "Activity", "Profile"] {
            XCTAssertTrue(
                app.tabBars.buttons[label].exists,
                "Expected a \(label) tab in the tab bar"
            )
        }
    }

    func testHomeShowsProgressMenu() throws {
        try skipUnlessSignedIn()
        goToHome()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        // The top-left progress menu is always present on Home (its label is
        // a constant icon with accessibility label "Choose progress").
        XCTAssertTrue(
            app.buttons["Choose progress"].exists,
            "Home tab should always expose the progress menu button"
        )
    }

    func testHomeShowsEitherEmptyStateOrContent() throws {
        try skipUnlessSignedIn()
        goToHome()
        _ = app.navigationBars["Home"].waitForExistence(timeout: 5)

        // Empty state (no progresses) OR content (a selected progress with
        // the "Add activity" toolbar button). Exactly one should hold.
        let emptyState = app.staticTexts["No progress yet"]
        let addActivity = app.buttons["Add activity"]
        let sawEmpty = emptyState.waitForExistence(timeout: 3)
        let sawContent = addActivity.exists

        XCTAssertTrue(
            sawEmpty || sawContent,
            "Home should show the empty state or a selected-progress content view"
        )
        XCTAssertFalse(
            sawEmpty && sawContent,
            "Empty state and content should be mutually exclusive"
        )
    }

    func testAddActivityButtonHiddenInEmptyState() throws {
        try skipUnlessSignedIn()
        goToHome()
        _ = app.navigationBars["Home"].waitForExistence(timeout: 5)
        // Per §3.6 / §5.1, the top-right "Add activity" button only appears
        // when a progress is selected. If we're in the empty state, it must
        // be absent.
        if app.staticTexts["No progress yet"].exists {
            XCTAssertFalse(
                app.buttons["Add activity"].exists,
                "Add activity button must be hidden when there are no progresses"
            )
        } else {
            throw XCTSkip("A progress is already selected — empty state not shown.")
        }
    }

    // MARK: - Tier 3: seeded-state flows (stubs)

    func testCreateProgressFlow() throws {
        throw XCTSkip("""
        Needs a seeded/mock auth session. Once the app honors a UI-testing \
        launch argument to sign in a deterministic test user, implement: \
        open progress menu → 'Create progress…' → type title → Create → \
        assert the new title appears and 'Add activity' becomes visible.
        """)
    }

    func testDeleteProgressIsOwnerOnly() throws {
        throw XCTSkip("""
        Needs seeded owner + collaborator sessions. Implement: as owner, \
        assert 'Delete Progress' exists; as collaborator on a shared \
        progress, assert it does not (FUNCTIONALITY.md §3.5, §9.1).
        """)
    }
}
