import SwiftUI

struct CreateProgressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProgressStore.self) private var progressStore

    @State private var title = ""
    @State private var isSaving = false
    @State private var lastError: String?

    /// Return `true` if creation succeeded (sheet should dismiss).
    let onCreate: (String) async -> Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Progress name", text: $title)
                if let lastError {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("New progress")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            isSaving = true
                            lastError = nil
                            let ok = await onCreate(title)
                            isSaving = false
                            if ok {
                                dismiss()
                            } else {
                                lastError = progressStore.errorMessage
                            }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }
}
