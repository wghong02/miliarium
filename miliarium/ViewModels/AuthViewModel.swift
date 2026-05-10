import Foundation
import FirebaseAuth
import FirebaseFirestore
import Observation

private final class FirebaseAuthStateListener {
    private var handle: AuthStateDidChangeListenerHandle?

    func start(onChange: @escaping @Sendable (User?) -> Void) {
        handle = Auth.auth().addStateDidChangeListener { _, user in
            onChange(user)
        }
    }

    deinit {
        if let handle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }
}

@Observable
@MainActor
final class AuthViewModel {
    private(set) var user: User?
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    private let authListener = FirebaseAuthStateListener()

    init() {
        user = Auth.auth().currentUser
        authListener.start { [weak self] user in
            Task { @MainActor [weak self] in
                self?.user = user
                // Create user document if they're logged in
                if let user = user {
                    await self?.ensureUserDocumentExists(userId: user.uid, email: user.email ?? "")
                }
            }
        }
    }

    func signIn(email: String, password: String) async {
        await perform {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        }
    }

    func register(email: String, password: String) async {
        await perform {
            _ = try await Auth.auth().createUser(withEmail: email, password: password)
        }
    }

    func signOut() {
        errorMessage = nil
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ensures a user document exists in Firestore for the authenticated user.
    /// This is called automatically when the user authenticates or logs in.
    private func ensureUserDocumentExists(userId: String, email: String) async {
        let db = Firestore.firestore()
        let userRef = db.collection("users").document(userId)
        
        do {
            let doc = try await userRef.getDocument()
            if !doc.exists {
                // Create new user document if it doesn't exist
                try await userRef.setData([
                    "email": email,
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
            }
        } catch {
            // Log error but don't block authentication
            print("Error ensuring user document: \(error.localizedDescription)")
        }
    }

    private func perform(_ work: @Sendable () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}