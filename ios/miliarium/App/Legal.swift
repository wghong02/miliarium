import Foundation

/// Central place for the app's legal / support links, surfaced on the login
/// screen and in Profile. Pages are hosted on GitHub Pages
/// (source: wghong02.github.io/src/app/apps/{policy,terms,support}/miliarium).
enum Legal {
    static let termsURL = URL(string: "https://wghong02.github.io/apps/terms/miliarium")!
    static let privacyURL = URL(string: "https://wghong02.github.io/apps/policy/miliarium")!
    static let supportEmail = "wghong02@gmail.com"

    /// Shown near sign-in and in the moderation copy. Keep the "zero tolerance"
    /// wording — App Review looks for an explicit objectionable-content policy.
    static let agreementNotice =
        "By continuing you agree to our Terms of Use and Privacy Policy. "
        + "Miliarium has zero tolerance for objectionable content or abusive behavior."
}
