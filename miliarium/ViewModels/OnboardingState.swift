import Foundation
import Observation
import FirebaseFirestore

/// Lifecycle:
/// - `hasSeenWelcome` is set once the welcome sheet is dismissed for the
///   first time. Persists in `UserDefaults` so the sheet never shows again
///   on the same device — even after sign-out / sign-in.
/// - `hasDismissedTutorial` is set when the user taps the X on the banner.
///   The banner stops appearing globally; even if the user later deletes
///   all their data, it does not auto-reappear.
///
/// The current banner step is *computed*, not stored — derived from the
/// user's live progress / collection / activity counts. This service owns
/// the lightweight Firestore listeners that keep `collectionCount` and
/// `activityCount` in sync for whichever progress is currently selected.
@Observable
@MainActor
final class OnboardingState {
    private static let welcomeKey = "miliarium.onboarding.hasSeenWelcome"
    private static let dismissedKey = "miliarium.onboarding.hasDismissedTutorial"
    private static let calendarHintKey = "miliarium.onboarding.hasSeenCalendarHint"
    private static let mapHintKey = "miliarium.onboarding.hasSeenMapHint"
    private static let activityHintKey = "miliarium.onboarding.hasSeenActivityHint"
    private static let activitySheetHintKey = "miliarium.onboarding.hasSeenActivitySheetHint"

    var hasSeenWelcome: Bool {
        didSet { UserDefaults.standard.set(hasSeenWelcome, forKey: Self.welcomeKey) }
    }
    var hasDismissedTutorial: Bool {
        didSet { UserDefaults.standard.set(hasDismissedTutorial, forKey: Self.dismissedKey) }
    }
    /// Per-tab informational hint flags. Each banner appears once per
    /// device and is independently dismissible — they're not part of the
    /// Home tab's step machine.
    var hasSeenCalendarHint: Bool {
        didSet { UserDefaults.standard.set(hasSeenCalendarHint, forKey: Self.calendarHintKey) }
    }
    var hasSeenMapHint: Bool {
        didSet { UserDefaults.standard.set(hasSeenMapHint, forKey: Self.mapHintKey) }
    }
    var hasSeenActivityHint: Bool {
        didSet { UserDefaults.standard.set(hasSeenActivityHint, forKey: Self.activityHintKey) }
    }
    /// One-time hint shown at the top of the Create/Edit Activity sheet —
    /// explains which fields are required vs. optional and the "tap a
    /// placeholder to add it" pattern.
    var hasSeenActivitySheetHint: Bool {
        didSet { UserDefaults.standard.set(hasSeenActivitySheetHint, forKey: Self.activitySheetHintKey) }
    }

    /// Live count of collections in the currently-active progress.
    private(set) var collectionCount: Int = 0
    /// Live count of activities in the currently-active progress.
    private(set) var activityCount: Int = 0

    @ObservationIgnored private var collectionsListener: ListenerRegistration?
    @ObservationIgnored private var activitiesListener: ListenerRegistration?
    @ObservationIgnored private var currentProgressId: String?

    init() {
        let defaults = UserDefaults.standard
        self.hasSeenWelcome = defaults.bool(forKey: Self.welcomeKey)
        self.hasDismissedTutorial = defaults.bool(forKey: Self.dismissedKey)
        self.hasSeenCalendarHint = defaults.bool(forKey: Self.calendarHintKey)
        self.hasSeenMapHint = defaults.bool(forKey: Self.mapHintKey)
        self.hasSeenActivityHint = defaults.bool(forKey: Self.activityHintKey)
        self.hasSeenActivitySheetHint = defaults.bool(forKey: Self.activitySheetHintKey)
    }

    // MARK: - Public API

    func markWelcomeSeen() {
        hasSeenWelcome = true
    }

    func dismissTutorial() {
        hasDismissedTutorial = true
        tearDownListeners()
    }

    func markCalendarHintSeen()      { hasSeenCalendarHint = true }
    func markMapHintSeen()           { hasSeenMapHint      = true }
    func markActivityHintSeen()      { hasSeenActivityHint = true }
    func markActivitySheetHintSeen() { hasSeenActivitySheetHint = true }

    /// Resets all onboarding flags so the welcome sheet, Home-tab tutorial
    /// banner, and every per-tab hint reappear from scratch. Called from
    /// the Profile tab's "Show tutorial again" action.
    func resetOnboarding() {
        hasSeenWelcome = false
        hasDismissedTutorial = false
        hasSeenCalendarHint = false
        hasSeenMapHint = false
        hasSeenActivityHint = false
        hasSeenActivitySheetHint = false
    }

    /// Returns the step the banner should display, given the current
    /// progress-set size and the live collection/activity counts.
    func currentStep(progressCount: Int) -> TutorialStep {
        if hasDismissedTutorial { return .done }
        if progressCount == 0 { return .createProgress }
        if collectionCount == 0 { return .createCollection }
        if activityCount == 0 { return .createActivity }
        return .done
    }

    /// Re-sync the per-progress listeners. Call this on home appear and
    /// whenever the active `selectedProgressId` changes. Idempotent.
    func updateForActiveProgress(_ progressId: String?) {
        // Once the user has dismissed the tutorial we don't need to spend
        // any further Firestore reads on tracking counts.
        guard !hasDismissedTutorial else {
            tearDownListeners()
            return
        }
        if currentProgressId == progressId { return }
        currentProgressId = progressId
        tearDownListeners()
        collectionCount = 0
        activityCount = 0
        guard let progressId else { return }

        collectionsListener = activityCollectionService.setCollectionsListener(for: progressId) { [weak self] fetched in
            Task { @MainActor in
                self?.collectionCount = fetched.count
            }
        }
        activitiesListener = activityService.setActivitiesListener(for: progressId) { [weak self] fetched in
            Task { @MainActor in
                self?.activityCount = fetched.count
            }
        }
    }

    private func tearDownListeners() {
        collectionsListener?.remove()
        collectionsListener = nil
        activitiesListener?.remove()
        activitiesListener = nil
        currentProgressId = nil
    }
}

/// The three steps the banner walks the user through, in order. `done` is
/// the terminal state — when the step is `.done` no banner is shown.
enum TutorialStep: Int, Sendable {
    case createProgress = 1
    case createCollection = 2
    case createActivity = 3
    case done = 4

    static let totalSteps = 3

    /// `nil` when `.done` (banner hidden); otherwise 1, 2, or 3.
    var ordinal: Int? {
        self == .done ? nil : rawValue
    }

    var instruction: String {
        switch self {
        case .createProgress:
            return "Tap the picker in the top-left and choose “Create progress…” to set your first goal."
        case .createCollection:
            return "Tap the + on the Collections section to make your first collection (e.g. “Cities visited”)."
        case .createActivity:
            return "Tap the + in the top-right to add your first activity."
        case .done:
            return ""
        }
    }

    var icon: String {
        switch self {
        case .createProgress: return "square.stack.fill"
        case .createCollection: return "folder.badge.plus"
        case .createActivity: return "doc.badge.plus"
        case .done: return "checkmark.seal.fill"
        }
    }
}
