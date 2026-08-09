import Foundation
import OSLog
import FirebaseAuth
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
        // UI-test hook: start every launch signed out so auth flows are
        // deterministic and order-independent (Firebase otherwise persists
        // the session to the keychain across launches). Only active when the
        // `-uitest-reset-auth` launch argument is present.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset-auth") {
            try? Auth.auth().signOut()
        }
        user = Auth.auth().currentUser
        authListener.start { [weak self] user in
            Task { @MainActor [weak self] in
                self?.user = user
                // Idempotently materialize the matching `users/{uid}` doc
                // (with the explicit `userId` field that mirrors the doc id).
                if let user {
                    AppLogger.auth.debug("authStateChanged: user signed in uid=\(user.uid)")
                    do {
                        try await userService.ensureUserExists(
                            userId: user.uid,
                            email: user.email
                        )
                    } catch {
                        // Surfaced to the log; don't block sign-in.
                        AppLogger.auth.error("ensureUserExists failed uid=\(user.uid): \(error)")
                    }
                } else {
                    AppLogger.auth.debug("authStateChanged: user signed out")
                }
            }
        }
    }

    func signIn(email: String, password: String) async {
        AppLogger.auth.debug("signIn email=\(email)")
        await perform {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        }
        if errorMessage == nil {
            AppLogger.auth.debug("signIn succeeded email=\(email)")
        }
    }

    func register(email: String, password: String) async {
        AppLogger.auth.debug("register email=\(email)")
        await perform {
            _ = try await Auth.auth().createUser(withEmail: email, password: password)
        }
        if errorMessage == nil {
            AppLogger.auth.debug("register succeeded email=\(email)")
        }
    }

    func signOut() {
        AppLogger.auth.debug("signOut")
        errorMessage = nil
        do {
            try Auth.auth().signOut()
        } catch {
            AppLogger.auth.error("signOut failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Permanently deletes the signed-in user's account (App Store Review
    /// Guideline 5.1.1(v)). `password` re-authenticates the user, because
    /// `FirebaseAuth`'s `delete()` requires a recent login and the persisted
    /// session is usually too old to qualify.
    ///
    /// The Auth account is deleted **first**. The backend `onAuthUserDeleted`
    /// trigger reacts by deleting the `users/{uid}` profile doc, which in turn
    /// fires the `onUserDeleted` cascade that wipes the rest server-side (the
    /// user's subtree — deviceTokens, progressLinks, ... — and every progress
    /// they owned). See backend/accountDeletion.ts and backend/cascadeDeletes.ts.
    ///
    /// This ordering matters: deleting the profile doc from the client *before*
    /// the Auth account was gone fired the destructive cascade immediately, so
    /// a failed Auth deletion would leave the account alive with all its data
    /// already destroyed. Cascading off the Auth deletion means nothing is
    /// destroyed unless the account is actually gone — a failed delete here is
    /// fully recoverable.
    ///
    /// The auth-state listener flips `user` to `nil` on success, so the auth
    /// gate returns to the login screen automatically. Returns `true` on
    /// success; on failure `errorMessage` carries the reason.
    @discardableResult
    func deleteAccount(password: String) async -> Bool {
        guard let currentUser = Auth.auth().currentUser else { return false }
        let uid = currentUser.uid
        AppLogger.auth.debug("deleteAccount uid=\(uid)")
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            if let email = currentUser.email {
                let credential = EmailAuthProvider.credential(
                    withEmail: email, password: password
                )
                try await currentUser.reauthenticate(with: credential)
            }
            // Delete the Auth account first; the backend cascades the data
            // teardown off this deletion. Nothing is destroyed unless this
            // succeeds, so a failure here leaves the account fully intact.
            try await currentUser.delete()
            AppLogger.auth.debug("deleteAccount succeeded uid=\(uid)")
            return true
        } catch {
            AppLogger.auth.error("deleteAccount failed uid=\(uid): \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func perform(_ work: @Sendable () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            AppLogger.auth.error("auth operation failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }
}