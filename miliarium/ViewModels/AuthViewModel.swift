import Foundation
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
        user = Auth.auth().currentUser
        authListener.start { [weak self] user in
            Task { @MainActor [weak self] in
                self?.user = user
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
