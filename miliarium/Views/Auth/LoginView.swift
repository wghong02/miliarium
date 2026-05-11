import SwiftUI

struct LoginView: View {
    @Environment(AuthViewModel.self) private var auth

    @State private var email = ""
    @State private var password = ""
    @State private var mode: AuthMode = .signIn

    private enum AuthMode: String, CaseIterable {
        case signIn = "Sign in"
        case register = "Create account"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                }

                if let message = auth.errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(AuthMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        Task {
                            switch mode {
                            case .signIn:
                                await auth.signIn(email: email, password: password)
                            case .register:
                                await auth.register(email: email, password: password)
                            }
                        }
                    } label: {
                        HStack {
                            if auth.isBusy { ProgressView() }
                            Text(mode == .signIn ? "Sign in" : "Create account")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(auth.isBusy || email.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Welcome")
        }
    }
}

#Preview {
    FirebasePreviewRoot {
        LoginView()
            .environment(AuthViewModel())
    }
}
