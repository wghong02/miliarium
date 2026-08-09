import SwiftUI

/// App-wide character caps for user-entered text. Update here in one place
/// to change every form that uses these limits.
enum TextLimits {
    /// Cap for short identifier-like strings: user profile name, progress
    /// title, activity title, location custom name, invitation recipient.
    static let name = 40
    /// Cap for the progress summary field — longer free-form paragraph.
    static let summary = 120
}

/// Compact `current/limit` counter shared by every form that enforces a
/// character cap. Two styles:
/// - `.truncating` — input is silently truncated at the cap. Counter goes
///   **orange** when at the cap (hint that further typing is dropped).
/// - `.locking` — input is allowed past the cap and the form locks its
///   action. Counter goes **red** only when *over* the cap.
struct CharacterCounter: View {
    enum Style {
        case truncating
        case locking
    }

    let count: Int
    let limit: Int
    var style: Style = .truncating

    var body: some View {
        Text("\(count)/\(limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(highlightColor)
            .textCase(nil)
    }

    private var highlightColor: Color {
        switch style {
        case .truncating:
            return count >= limit ? .orange : .secondary
        case .locking:
            return count > limit ? .red : .secondary
        }
    }
}
