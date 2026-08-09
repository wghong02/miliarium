import XCTest

/// UI tests for the Home tab (FUNCTIONALITY.md §3).
///
/// `setUp` launches with `-uitest-reset-auth` (clean signed-out start) then
/// signs in with the shared `TestAccount`, so every test here runs against a
/// real authenticated session. These tests require network connectivity.
///
/// Read-only assertions (tab bar shape, progress menu, empty-vs-content)
/// run directly. Data-mutating flows (create / delete progress) are left as
/// stubs: create-progress needs self-cleanup to avoid polluting the shared
/// account, and delete-owner-only needs a second (collaborator) account.
final class HomeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Skips the whole suite when TestSecrets.json is absent.
        let creds = try requireTestCredentials()
        app = XCUIApplication()
        app.launchForUITesting()
        app.signIn(with: creds)   // fails the test if sign-in doesn't land
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func goToHome() {
        let homeTab = app.tabBars.buttons["Home"]
        if homeTab.exists { homeTab.tap() }
    }

    // MARK: - Tab bar

    func testTabBarHasFiveTabs() {
        for label in ["Home", "Calendar", "Map", "Activity", "Profile"] {
            XCTAssertTrue(
                app.tabBars.buttons[label].exists,
                "Expected a \(label) tab in the tab bar"
            )
        }
    }

    // MARK: - §3.2 / §3.6 progress menu

    func testHomeShowsProgressMenu() {
        goToHome()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        // The top-left progress menu is always present on Home (its label is
        // a constant icon with accessibility label "Choose progress").
        XCTAssertTrue(
            app.buttons["Choose progress"].exists,
            "Home tab should always expose the progress menu button"
        )
    }

    // MARK: - §3.6 body states

    func testHomeShowsEitherEmptyStateOrContent() {
        goToHome()
        _ = app.navigationBars["Home"].waitForExistence(timeout: 5)

        // Empty state (no progresses) OR content (a selected progress with
        // the "Add activity" toolbar button). Exactly one should hold.
        let emptyState = app.staticTexts["No progress yet"]
        let addActivity = app.buttons["Add activity"]
        let sawEmpty = emptyState.waitForExistence(timeout: 5)
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

    func testAddActivityButtonVisibilityMatchesSelection() throws {
        goToHome()
        _ = app.navigationBars["Home"].waitForExistence(timeout: 5)
        // Per §3.6 / §5.1, the top-right "Add activity" button appears only
        // when a progress is selected.
        if app.staticTexts["No progress yet"].waitForExistence(timeout: 5) {
            XCTAssertFalse(
                app.buttons["Add activity"].exists,
                "Add activity button must be hidden when there are no progresses"
            )
        } else {
            XCTAssertTrue(
                app.buttons["Add activity"].exists,
                "Add activity button should be visible when a progress is selected"
            )
        }
    }

    // MARK: - Data-mutating flows (stubs)

    func testCreateProgressFlow() throws {
        throw XCTSkip("""
        Runnable now that a session is available, but must self-clean to \
        avoid polluting the shared test account: open progress menu → \
        'Create progress…' → type a unique title → Create → assert it appears \
        and 'Add activity' becomes visible → then delete it in the same test.
        """)
    }

    func testDeleteProgressIsOwnerOnly() throws {
        throw XCTSkip("""
        Needs a second (collaborator) account to assert the negative case. \
        Implement: as owner, assert 'Delete Progress' exists; as collaborator \
        on a shared progress, assert it does not (FUNCTIONALITY.md §3.5, §9.1).
        """)
    }
}
