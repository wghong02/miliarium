import SwiftUI

struct EditSummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProgressStore.self) private var progressStore

    let progressId: String
    let initialSummary: String
    var onDismiss: () -> Void = {}

    @State private var summary: String = ""
    @State private var isUpdating = false
    @State private var errorMessage: String?

    private let characterLimit = 120
    private var isOverLimit: Bool {
        summary.count > characterLimit
    }
    private var remainingCharacters: Int {
        max(0, characterLimit - summary.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $summary)
                        .frame(minHeight: 120)
                } header: {
                    HStack {
                        Text("Summary")
                        Spacer()
                        Text("\(summary.count)/\(characterLimit)")
                            .font(.caption)
                            .foregroundStyle(isOverLimit ? .red : .secondary)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    HStack {
                        Button(action: updateSummary) {
                            if isUpdating {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else {
                                Text("Update Summary")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .disabled(isUpdating || isOverLimit)

                        if isOverLimit {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Edit Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                summary = initialSummary
            }
        }
    }

    private func updateSummary() {
        isUpdating = true
        errorMessage = nil

        Task {
            let success = await progressStore.updateProgressSummary(
                progressId: progressId,
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            await MainActor.run {
                isUpdating = false
                if success {
                    onDismiss()
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    EditSummarySheet(progressId: "test123", initialSummary: "Sample summary")
        .environment(ProgressStore())
}
