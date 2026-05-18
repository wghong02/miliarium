import Foundation
import FirebaseFirestore

class MilestoneService {
    private let db = Firestore.firestore()

    // MARK: - Create

    func createMilestone(
        progressItemId: String,
        name: String,
        type: MilestoneType,
        counter: Int? = nil,
        completed: Bool? = nil,
        targetDate: Date? = nil
    ) async throws {
        let milestone = Milestone(
            name: name,
            type: type,
            counter: counter,
            completed: completed,
            targetDate: targetDate
        )

        let milestonesRef = db.collection("progressItems")
            .document(progressItemId)
            .collection("milestones")
            .document(milestone.id)

        try await milestonesRef.setData(milestone.asFirestoreMap())
    }

    // MARK: - Read

    func fetchMilestones(for progressItemId: String) async throws -> [Milestone] {
        let snapshot = try await db.collection("progressItems")
            .document(progressItemId)
            .collection("milestones")
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { Milestone(document: $0) }
    }

    func fetchMilestone(id: String, for progressItemId: String) async throws -> Milestone? {
        let doc = try await db.collection("progressItems")
            .document(progressItemId)
            .collection("milestones")
            .document(id)
            .getDocument()

        return Milestone(document: doc)
    }

    func fetchMilestonesByType(
        _ type: MilestoneType,
        for progressItemId: String
    ) async throws -> [Milestone] {
        let snapshot = try await db.collection("progressItems")
            .document(progressItemId)
            .collection("milestones")
            .whereField("type", isEqualTo: type.rawValue)
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { Milestone(document: $0) }
    }

    // MARK: - Update

    func updateMilestone(
        _ milestone: Milestone,
        progressItemId: String,
        name: String? = nil,
        counter: Int? = nil,
        completed: Bool? = nil,
        targetDate: Date? = nil
    ) async throws {
        var updatedMilestone = milestone
        updatedMilestone.updatedAt = Date()

        if let name = name {
            updatedMilestone.name = name
        }
        if let counter = counter {
            updatedMilestone.counter = counter
        }
        if let completed = completed {
            updatedMilestone.completed = completed
        }
        if let targetDate = targetDate {
            updatedMilestone.targetDate = targetDate
        }

        let milestonesRef = db.collection("progressItems")
            .document(progressItemId)
            .collection("milestones")
            .document(milestone.id)

        try await milestonesRef.setData(updatedMilestone.asFirestoreMap())
    }

    func incrementMilestoneCounter(_ milestone: Milestone, progressItemId: String) async throws {
        let newCounter = (milestone.counter ?? 0) + 1
        try await updateMilestone(milestone, progressItemId: progressItemId, counter: newCounter)
    }

    func decrementMilestoneCounter(_ milestone: Milestone, progressItemId: String) async throws {
        let newCounter = max(0, (milestone.counter ?? 0) - 1)
        try await updateMilestone(milestone, progressItemId: progressItemId, counter: newCounter)
    }

    func setMilestoneCounter(_ milestone: Milestone, progressItemId: String, value: Int) async throws {
        let newCounter = max(0, value)
        try await updateMilestone(milestone, progressItemId: progressItemId, counter: newCounter)
    }

    func toggleMilestoneCompletion(_ milestone: Milestone, progressItemId: String) async throws {
        let newCompleted = !(milestone.completed ?? false)
        try await updateMilestone(milestone, progressItemId: progressItemId, completed: newCompleted)
    }

    func updateMilestoneDate(_ milestone: Milestone, progressItemId: String, newDate: Date) async throws {
        try await updateMilestone(milestone, progressItemId: progressItemId, targetDate: newDate)
    }

    // MARK: - Delete

    func deleteMilestone(_ milestoneId: String, for progressItemId: String) async throws {
        let milestonesRef = db.collection("progressItems")
            .document(progressItemId)
            .collection("milestones")
            .document(milestoneId)

        try await milestonesRef.delete()
    }

    func deleteAllMilestones(for progressItemId: String) async throws {
        let snapshot = try await db.collection("progressItems")
            .document(progressItemId)
            .collection("milestones")
            .getDocuments()

        let batch = db.batch()
        for doc in snapshot.documents {
            batch.deleteDocument(doc.reference)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            batch.commit { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Listener

    func setMilestonesListener(
        for progressItemId: String,
        onChange: @escaping ([Milestone]) -> Void
    ) -> ListenerRegistration {
        let query = db.collection("progressItems")
            .document(progressItemId)
            .collection("milestones")
            .order(by: "createdAt", descending: true)

        return query.addSnapshotListener { snapshot, error in
            if let error {
                print("[MilestoneService] Listener error: \(error.localizedDescription)")
                return
            }

            guard let snapshot = snapshot else {
                print("[MilestoneService] Snapshot is nil")
                return
            }

            let milestones = snapshot.documents.compactMap { Milestone(document: $0) }
            onChange(milestones)
        }
    }
}

let milestoneService = MilestoneService()
