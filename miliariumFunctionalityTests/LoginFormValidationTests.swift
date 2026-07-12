import Testing
@testable import miliarium

/// Unit tests for the sign-in / create-account submit rule
/// (FUNCTIONALITY.md §1.1: "Empty email or password keeps the action
/// disabled" + "Fields cannot be edited / action locked while a request is
/// in flight").
///
/// `AuthViewModel` itself is entirely Firebase-coupled (every method calls
/// `Auth.auth()`), so its sign-in/out behaviour is covered by the UI tests
/// (`AuthUITests`) and, for real credential paths, would need the Firebase
/// Auth emulator. The one piece of pure §1 logic is this validation rule.
@Suite("LoginFormValidation")
struct LoginFormValidationTests {

    @Test("Enabled only when both fields filled and not busy")
    func happyPath() {
        #expect(LoginFormValidation.canSubmit(email: "a@b.com", password: "pw", isBusy: false))
    }

    @Test("Disabled when email is empty")
    func emptyEmail() {
        #expect(!LoginFormValidation.canSubmit(email: "", password: "pw", isBusy: false))
    }

    @Test("Disabled when password is empty")
    func emptyPassword() {
        #expect(!LoginFormValidation.canSubmit(email: "a@b.com", password: "", isBusy: false))
    }

    @Test("Disabled when both fields empty")
    func bothEmpty() {
        #expect(!LoginFormValidation.canSubmit(email: "", password: "", isBusy: false))
    }

    @Test("Disabled while a request is in flight, even with both fields filled")
    func busyLocksSubmit() {
        #expect(!LoginFormValidation.canSubmit(email: "a@b.com", password: "pw", isBusy: true))
    }

    /// Documents current behaviour: the check is a plain `.isEmpty`, so a
    /// whitespace-only email is treated as "filled" and enables submit
    /// (Firebase then rejects it with an inline error). If we later decide
    /// to trim per §11's whitespace rule, flip this expectation.
    @Test("Whitespace-only email currently enables submit (no trimming)")
    func whitespaceEmailNotTrimmed() {
        #expect(LoginFormValidation.canSubmit(email: "   ", password: "pw", isBusy: false))
    }
}
