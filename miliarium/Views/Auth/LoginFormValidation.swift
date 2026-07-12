import Foundation

/// Pure, testable submit-enablement rule for the sign-in / create-account
/// form (FUNCTIONALITY.md §1.1). Extracted from `LoginView` so the logic can
/// be unit-tested without standing up a SwiftUI view or Firebase.
///
/// Behaviour is intentionally identical to the previous inline check
/// (`auth.isBusy || email.isEmpty || password.isEmpty` on the button's
/// `.disabled` modifier): submit is allowed only when a request isn't
/// already in flight and both fields are non-empty.
enum LoginFormValidation {
    /// `true` when the sign-in / create-account button should be tappable.
    static func canSubmit(email: String, password: String, isBusy: Bool) -> Bool {
        !isBusy && !email.isEmpty && !password.isEmpty
    }
}
