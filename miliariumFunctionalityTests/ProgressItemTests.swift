import Testing
@testable import miliarium

/// Unit tests for `ProgressItem` / `ProgressContent` / `ProgressRole`.
///
/// These back the Home tab's owner-gating behavior (FUNCTIONALITY.md §3.3,
/// §3.5, §3.6): the pencil "edit summary" button, the "Send Invitation"
/// block, the Invited Users panel, and the "Delete Progress" button are all
/// shown only when the current user is the owner of the selected progress.
/// Ownership resolution ultimately bottoms out in `inferredRole(forUserId:)`.
@Suite("ProgressItem")
struct ProgressItemTests {

    // MARK: - Role inference

    @Test("Owner is inferred when userId matches ownerUserId")
    func inferredRoleOwner() {
        let item = ProgressItem(
            id: "p1",
            title: "Travel 2026",
            content: ProgressContent(),
            ownerUserId: "user-abc"
        )
        #expect(item.inferredRole(forUserId: "user-abc") == .owner)
    }

    @Test("Collaborator is inferred when userId differs from ownerUserId")
    func inferredRoleCollaborator() {
        let item = ProgressItem(
            id: "p1",
            title: "Travel 2026",
            content: ProgressContent(),
            ownerUserId: "user-abc"
        )
        #expect(item.inferredRole(forUserId: "user-xyz") == .collaborator)
    }

    @Test("Empty ownerUserId never infers owner for a real user")
    func inferredRoleEmptyOwner() {
        // Parsing a malformed doc yields ownerUserId == "" — a signed-in
        // user must not accidentally be treated as owner of it.
        let item = ProgressItem(
            id: "p1",
            title: "Untitled",
            content: ProgressContent(),
            ownerUserId: ""
        )
        #expect(item.inferredRole(forUserId: "user-abc") == .collaborator)
    }

    // MARK: - ProgressRole raw values

    @Test("ProgressRole raw values are stable Firestore strings")
    func roleRawValues() {
        #expect(ProgressRole.owner.rawValue == "owner")
        #expect(ProgressRole.collaborator.rawValue == "collaborator")
        #expect(ProgressRole(rawValue: "owner") == .owner)
        #expect(ProgressRole(rawValue: "collaborator") == .collaborator)
        #expect(ProgressRole(rawValue: "viewer") == nil)
    }

    // MARK: - ProgressContent round-trip

    @Test("ProgressContent round-trips through Firestore map")
    func contentRoundTrip() {
        let content = ProgressContent(summary: "A short summary", body: "Longer body text")
        let restored = ProgressContent.fromFirestore(content.asFirestoreMap())
        #expect(restored.summary == "A short summary")
        #expect(restored.body == "Longer body text")
    }

    @Test("ProgressContent.fromFirestore tolerates nil and wrong types")
    func contentFromGarbage() {
        #expect(ProgressContent.fromFirestore(nil).summary.isEmpty)
        #expect(ProgressContent.fromFirestore(nil).body.isEmpty)
        // A non-map value falls back to empty content, not a crash.
        let fromString = ProgressContent.fromFirestore("not a map")
        #expect(fromString.summary.isEmpty)
        #expect(fromString.body.isEmpty)
        // A partial map keeps present keys and defaults missing ones.
        let partial = ProgressContent.fromFirestore(["summary": "only summary"])
        #expect(partial.summary == "only summary")
        #expect(partial.body.isEmpty)
    }

    @Test("Default ProgressContent is empty")
    func contentDefaults() {
        let content = ProgressContent()
        #expect(content.summary.isEmpty)
        #expect(content.body.isEmpty)
    }
}
