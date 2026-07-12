import XCTest

/// UI tests for Authentication (FUNCTIONALITY.md §1).
///
/// Every launch uses `-uitest-reset-auth`, so each test starts signed out.
/// The credential round-trip flows use the shared `TestAccount` and hit the
/// real Firebase Auth backend — they require network connectivity.
///
/// The submit button is queried via its accessibility identifier
/// `authSubmitButton` because its visible title ("Sign in" / "Create
/// account") collides with the mode segmented control's segment labels.
final class AuthUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchForUITesting()   // deterministic signed-out start
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Element accessors

    private var welcomeBar: XCUIElement { app.navigationBars["Welcome"] }
    private var emailField: XCUIElement { app.textFields["Email"] }
    private var passwordField: XCUIElement { app.secureTextFields["Password"] }
    private var submitButton: XCUIElement { app.buttons["authSubmitButton"] }

    /// Asserts the login screen is showing (guaranteed by `-uitest-reset-auth`).
    private func assertOnLoginScreen() {
        XCTAssertTrue(
            welcomeBar.waitForExistence(timeout: 10),
            "Expected the 'Welcome' login screen after reset-auth launch"
        )
    }

    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        field.typeText(text)
    }

    // MARK: - §1.1 Sign in — form structure

    func testLoginFormShowsEmailPasswordAndAction() {
        assertOnLoginScreen()
        XCTAssertTrue(emailField.exists, "Email field should be present")
        XCTAssertTrue(passwordField.exists, "Password field should be present")
        XCTAssertTrue(submitButton.exists, "Submit button should be present")
    }

    // MARK: - §1.1 Sign in — submit enablement

    func testSubmitDisabledWhenBothFieldsEmpty() {
        assertOnLoginScreen()
        XCTAssertFalse(
            submitButton.isEnabled,
            "Submit must be disabled when email and password are both empty"
        )
    }

    func testSubmitDisabledWithOnlyEmail() {
        assertOnLoginScreen()
        type("user@example.com", into: emailField)
        XCTAssertFalse(
            submitButton.isEnabled,
            "Submit must stay disabled until the password is also entered"
        )
    }

    func testSubmitEnablesWhenBothFieldsFilled() {
        assertOnLoginScreen()
        type("user@example.com", into: emailField)
        type("supersecret", into: passwordField)
        XCTAssertTrue(
            submitButton.isEnabled,
            "Submit should enable once both fields are non-empty"
        )
    }

    // MARK: - §1.1 Sign in — mode switch

    func testModeSwitchChangesSubmitTitle() {
        assertOnLoginScreen()
        XCTAssertEqual(submitButton.label, "Sign in")
        let createSegment = app.segmentedControls.buttons["Create account"]
        XCTAssertTrue(createSegment.waitForExistence(timeout: 3))
        createSegment.tap()
        XCTAssertEqual(
            submitButton.label,
            "Create account",
            "Switching mode should relabel the action button"
        )
    }

    // MARK: - §1.1 Sign in — credential round-trips

    func testSignInWithValidCredentialsEntersApp() throws {
        let creds = try requireTestCredentials()
        assertOnLoginScreen()
        type(creds.email, into: emailField)
        type(creds.password, into: passwordField)
        submitButton.tap()
        XCTAssertTrue(
            app.waitForTabBar(),
            "Valid credentials should move the user into the main tab view"
        )
        // Sanity: the five tabs are present.
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
    }

    func testSignInWithInvalidCredentialsShowsInlineError() throws {
        let creds = try requireTestCredentials()
        assertOnLoginScreen()
        type(creds.email, into: emailField)
        type("definitely-the-wrong-password", into: passwordField)
        submitButton.tap()

        // A red inline error row should appear...
        XCTAssertTrue(
            app.staticTexts["authErrorMessage"].waitForExistence(timeout: 15),
            "Invalid credentials should surface an inline error"
        )
        // ...and we must NOT have entered the app.
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Bad credentials must not sign in")
        XCTAssertTrue(welcomeBar.exists, "Should remain on the login screen")
    }

    // MARK: - §1.2 Sign out

    func testSignOutReturnsToLoginForm() throws {
        // Arrange: sign in first.
        app.signIn(with: try requireTestCredentials())

        // Act: Profile tab → Sign out.
        app.tabBars.buttons["Profile"].tap()
        let signOut = app.buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "Profile should expose Sign out")
        signOut.tap()

        // Assert: the auth gate returns to the login form.
        XCTAssertTrue(
            welcomeBar.waitForExistence(timeout: 10),
            "After sign-out the login screen should return (§1.2)"
        )
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Tab bar should be gone after sign-out")
    }
}
