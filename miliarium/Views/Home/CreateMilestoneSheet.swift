import SwiftUI

struct CreateMilestoneSheet: View {
    @Environment(\.dismiss) private var dismiss

    let progressItemId: String
    var onMilestoneCreated: () -> Void = {}

    @State private var milestoneName = ""
    @State private var selectedType: MilestoneType = .count
    @State private var counterValueText = "0"
    @State private var isCompleted = false
    @State private var targetDate = Date().addingTimeInterval(86400 * 7) // 1 week from now
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var counterValue: Int {
        Int(counterValueText) ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Milestone Details") {
                    TextField("Milestone name", text: $milestoneName)

                    Picker("Type", selection: $selectedType) {
                        ForEach([MilestoneType.count, .achievement, .timeline], id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Type-Specific Details") {
                    switch selectedType {
                    case .count:
                        VStack(spacing: 12) {
                            HStack {
                                Text("Starting value")
                                Spacer()
                                TextField("0", text: $counterValueText)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                            }
                            HStack(spacing: 12) {
                                Spacer()
                                Button(action: {
                                    let current = Int(counterValueText) ?? 0
                                    counterValueText = String(max(0, current - 1))
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title3)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)

                                Text("\(counterValue)")
                                    .monospacedDigit()
                                    .font(.title3)
                                    .foregroundStyle(.blue)

                                Button(action: {
                                    let current = Int(counterValueText) ?? 0
                                    counterValueText = String(current + 1)
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)

                                Spacer()
                            }
                        }

                    case .achievement:
                        Toggle("Completed", isOn: $isCompleted)

                    case .timeline:
                        DatePicker("Date", selection: $targetDate, displayedComponents: .date)
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
                    Button(action: createMilestone) {
                        if isCreating {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("Create Milestone")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .disabled(milestoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
            .navigationTitle("New Milestone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func createMilestone() {
        let trimmedName = milestoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isCreating = true
        errorMessage = nil

        Task {
            do {
                try await milestoneService.createMilestone(
                    progressItemId: progressItemId,
                    name: trimmedName,
                    type: selectedType,
                    counter: selectedType == .count ? counterValue : nil,
                    completed: selectedType == .achievement ? isCompleted : nil,
                    targetDate: selectedType == .timeline ? targetDate : nil
                )

                await MainActor.run {
                    isCreating = false
                    onMilestoneCreated()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct EditMilestoneSheet: View {
    @Environment(\.dismiss) private var dismiss

    let milestone: Milestone
    let progressItemId: String
    var onDismiss: () -> Void = {}

    @State private var milestoneName: String = ""
    @State private var counterValueText: String = "0"
    @State private var isCompleted: Bool = false
    @State private var targetDate: Date = Date()
    @State private var isUpdating = false
    @State private var errorMessage: String?

    private var counterValue: Int {
        Int(counterValueText) ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Milestone Details") {
                    TextField("Milestone name", text: $milestoneName)
                    Text(milestone.type.displayName)
                        .foregroundStyle(.secondary)
                }

                Section("Details") {
                    switch milestone.type {
                    case .count:
                        VStack(spacing: 12) {
                            HStack {
                                Text("Count")
                                Spacer()
                                TextField("0", text: $counterValueText)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                            }
                            HStack(spacing: 12) {
                                Spacer()
                                Button(action: {
                                    let current = Int(counterValueText) ?? 0
                                    counterValueText = String(max(0, current - 1))
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title3)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)

                                Text("\(counterValue)")
                                    .monospacedDigit()
                                    .font(.title3)
                                    .foregroundStyle(.blue)

                                Button(action: {
                                    let current = Int(counterValueText) ?? 0
                                    counterValueText = String(current + 1)
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)

                                Spacer()
                            }
                        }

                    case .achievement:
                        Toggle("Completed", isOn: $isCompleted)

                    case .timeline:
                        DatePicker("Date", selection: $targetDate, displayedComponents: .date)
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
                    Button(action: updateMilestone) {
                        if isUpdating {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("Update Milestone")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .disabled(milestoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUpdating)
                }
            }
            .navigationTitle("Edit Milestone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
            .onAppear {
                milestoneName = milestone.name
                counterValueText = String(milestone.counter ?? 0)
                isCompleted = milestone.completed ?? false
                targetDate = milestone.targetDate ?? Date()
            }
        }
    }

    private func updateMilestone() {
        let trimmedName = milestoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isUpdating = true
        errorMessage = nil

        Task {
            do {
                try await milestoneService.updateMilestone(
                    milestone,
                    progressItemId: progressItemId,
                    name: trimmedName,
                    counter: milestone.type == .count ? counterValue : nil,
                    completed: milestone.type == .achievement ? isCompleted : nil,
                    targetDate: milestone.type == .timeline ? targetDate : nil
                )

                await MainActor.run {
                    isUpdating = false
                    onDismiss()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isUpdating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    CreateMilestoneSheet(progressItemId: "test123")
}
