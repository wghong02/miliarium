import Testing
@testable import miliarium

/// Unit tests for the Home-tab tutorial banner state machine
/// (FUNCTIONALITY.md §13.2) and the `TutorialStep` value type.
///
/// Focus: the *flash-prevention gating* added to stop the banner briefly
/// appearing on app launch (`currentStep` must return `.done` until the
/// data is confirmed loaded). Branches that depend on the live
/// collection/activity Firestore listeners (`.createCollection` /
/// `.createActivity`) are not reachable from a pure unit test because those
/// counts are only mutated by listener callbacks — they need integration
/// coverage against the Firebase emulator.
///
/// The suite is `.serialized` because `OnboardingState` persists flags to
/// `UserDefaults.standard`; parallel execution would race on that shared
/// store. Each test gets a fresh, normalized instance via `init()`.
@MainActor
@Suite("OnboardingState", .serialized)
struct OnboardingStateTests {

    let state: OnboardingState

    init() {
        state = OnboardingState()
        // Normalize the persisted flags to a known "fresh install" baseline
        // so tests don't inherit dirty defaults from the test host.
        state.resetOnboarding()
    }

    // MARK: - TutorialStep value type

    @Test("TutorialStep exposes exactly 3 actionable steps")
    func totalSteps() {
        #expect(TutorialStep.totalSteps == 3)
    }

    @Test("Ordinals are 1...3 for actionable steps and nil for done")
    func ordinals() {
        #expect(TutorialStep.createProgress.ordinal == 1)
        #expect(TutorialStep.createCollection.ordinal == 2)
        #expect(TutorialStep.createActivity.ordinal == 3)
        #expect(TutorialStep.done.ordinal == nil)
    }

    @Test("Actionable steps have non-empty instruction + icon; done is empty")
    func stepPresentation() {
        for step in [TutorialStep.createProgress, .createCollection, .createActivity] {
            #expect(!step.instruction.isEmpty)
            #expect(!step.icon.isEmpty)
        }
        #expect(TutorialStep.done.instruction.isEmpty)
    }

    // MARK: - currentStep gating (flash prevention)

    @Test("Before progresses load, step is hidden regardless of count")
    func hiddenBeforeInitialization() {
        // Fresh instance: hasInitializedProgresses is false. Even though a
        // zero count would otherwise mean 'createProgress', we stay quiet.
        #expect(state.currentStep(progressCount: 0) == .done)
        #expect(state.currentStep(progressCount: 3) == .done)
    }

    @Test("After load with zero progresses, step is createProgress")
    func createProgressAfterLoad() {
        state.markProgressesInitialized()
        #expect(state.currentStep(progressCount: 0) == .createProgress)
    }

    @Test("With progresses but sub-listeners not ready, step stays hidden")
    func hiddenUntilSubListenersReady() {
        // Progresses are loaded and there's at least one, but the
        // per-progress collection/activity listeners haven't delivered yet.
        // We must not flash step 2 or 3 prematurely.
        state.markProgressesInitialized()
        #expect(state.currentStep(progressCount: 2) == .done)
    }

    @Test("Dismissing the tutorial forces done in every configuration")
    func dismissedAlwaysDone() {
        state.markProgressesInitialized()
        state.hasDismissedTutorial = true
        #expect(state.currentStep(progressCount: 0) == .done)
        #expect(state.currentStep(progressCount: 5) == .done)
    }

    // MARK: - Persistence + reset

    @Test("markWelcomeSeen persists across instances")
    func welcomePersists() {
        #expect(state.hasSeenWelcome == false)   // reset baseline
        state.markWelcomeSeen()
        #expect(state.hasSeenWelcome == true)
        // A brand-new instance reads the persisted flag from UserDefaults.
        let reloaded = OnboardingState()
        #expect(reloaded.hasSeenWelcome == true)
        reloaded.resetOnboarding()               // clean up shared defaults
    }

    @Test("resetOnboarding clears every one-time flag")
    func resetClearsAll() {
        state.markWelcomeSeen()
        state.hasDismissedTutorial = true
        state.markCalendarHintSeen()
        state.markMapHintSeen()
        state.markActivityHintSeen()
        state.markActivitySheetHintSeen()

        state.resetOnboarding()

        #expect(state.hasSeenWelcome == false)
        #expect(state.hasDismissedTutorial == false)
        #expect(state.hasSeenCalendarHint == false)
        #expect(state.hasSeenMapHint == false)
        #expect(state.hasSeenActivityHint == false)
        #expect(state.hasSeenActivitySheetHint == false)
    }

    @Test("Per-tab hint flags are independent")
    func hintFlagsIndependent() {
        state.markCalendarHintSeen()
        #expect(state.hasSeenCalendarHint == true)
        // Dismissing the calendar hint must not touch the others.
        #expect(state.hasSeenMapHint == false)
        #expect(state.hasSeenActivityHint == false)
    }
}
