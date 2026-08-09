import XCTest

/// Anchor class used to resolve the UI-test bundle for resource lookups.
final class UITestBundleMarker {}

/// Throwaway account used only by the UI test suite. The actual values live
/// in the **git-ignored** `TestSecrets.json` (copy from
/// `TestSecrets.example.json`), which is bundled into the test target as a
/// resource and loaded at runtime. When the file is absent (e.g. a fresh
/// clone or CI without secrets), `credentials` is `nil` and auth-dependent
/// tests skip rather than fail — the target still compiles either way.
enum TestAccount {
    struct Credentials: Decodable {
        let email: String
        let password: String
    }

    static let credentials: Credentials? = {
        guard let url = Bundle(for: UITestBundleMarker.self)
                .url(forResource: "TestSecrets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let creds = try? JSONDecoder().decode(Credentials.self, from: data)
        else { return nil }
        return creds
    }()
}

extension XCTestCase {
    /// Returns the test credentials, or throws `XCTSkip` when `TestSecrets.json`
    /// is missing so auth-dependent tests skip cleanly.
    func requireTestCredentials(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TestAccount.Credentials {
        guard let creds = TestAccount.credentials else {
            throw XCTSkip(
                "TestSecrets.json not found — copy TestSecrets.example.json and fill "
                + "in a throwaway account to run auth-dependent UI tests."
            )
        }
        return creds
    }
}

extension XCUIApplication {
    /// Launches the app in a deterministic signed-out state for UI testing.
    func launchForUITesting() {
        launchArguments += ["-uitest-reset-auth"]
        launch()
    }

    /// Waits for the authenticated tab bar (post sign-in) to appear.
    @discardableResult
    func waitForTabBar(timeout: TimeInterval = 15) -> Bool {
        tabBars.firstMatch.waitForExistence(timeout: timeout)
    }

    /// Signs in with the given credentials from the login screen and asserts
    /// the tab bar appears. No-op if already signed in.
    func signIn(
        with credentials: TestAccount.Credentials,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if tabBars.firstMatch.exists { return }

        let email = textFields["Email"]
        XCTAssertTrue(
            email.waitForExistence(timeout: 10),
            "Login email field not found — is the app on the Welcome screen?",
            file: file, line: line
        )

        // Make sure the mode picker is on "Sign in" (not "Create account"),
        // otherwise the submit button would try to *register* the already-
        // existing test account instead of signing in.
        let signInSegment = segmentedControls.buttons["Sign in"]
        if signInSegment.exists && !signInSegment.isSelected {
            signInSegment.tap()
        }

        focusAndType(email, credentials.email)
        focusAndType(secureTextFields["Password"], credentials.password)

        // Trigger the sign-in button — but only once it's actually enabled.
        // The button is `.disabled(...email.isEmpty || password.isEmpty)`, so
        // tapping before SwiftUI has registered the typed text is a silent
        // no-op that never signs in (→ the tab-bar timeout below).
        let submit = buttons["authSubmitButton"]
        XCTAssertTrue(
            submit.waitForExistence(timeout: 5),
            "Sign-in submit button not found",
            file: file, line: line
        )
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: submit
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [enabled], timeout: 5), .completed,
            "Sign-in button never became enabled — credentials didn't register",
            file: file, line: line
        )
        submit.tap()

        XCTAssertTrue(
            waitForTabBar(),
            "Did not reach the tab bar within 15s after signing in",
            file: file, line: line
        )
    }

    /// Taps a field and types into it, guarding against the intermittent
    /// "Neither element nor any descendant has keyboard focus" failure where
    /// the first tap doesn't acquire focus. Retries the tap once if the
    /// keyboard hasn't appeared.
    private func focusAndType(_ field: XCUIElement, _ text: String) {
        field.tap()
        if !keyboards.element.waitForExistence(timeout: 2) {
            field.tap()
        }
        field.typeText(text)
    }
}
