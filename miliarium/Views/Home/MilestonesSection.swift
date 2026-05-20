import SwiftUI
import FirebaseFirestore

struct MilestonesSection: View {
    let progressItemId: String

    @State private var milestones: [Milestone] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listener: ListenerRegistration?
    @State private var listenerInitialized = false
    @State private var selectedFilter: MilestoneType? = nil
    @State private var showCreateMilestone = false
    @State private var deletingMilestoneId: String?

    var filteredMilestones: [Milestone] {
        if let filter = selectedFilter {
            return milestones.filter { $0.type == filter }
        }
        return milestones
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with title and create button
            HStack {
                Text("Milestones")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button(action: { showCreateMilestone = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.headline)
                    }
                    .foregroundStyle(.blue)
                }
            }
            .padding()

            // Filter buttons
            HStack(spacing: 8) {
                FilterButton(
                    label: "All",
                    isSelected: selectedFilter == nil,
                    action: { selectedFilter = nil }
                )

                ForEach([MilestoneType.count, .achievement, .timeline], id: \.self) { type in
                    FilterButton(
                        label: type.displayName,
                        isSelected: selectedFilter == type,
                        action: { selectedFilter = type }
                    )
                }

                Spacer()
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Milestones list
            if filteredMilestones.isEmpty {
                VStack(spacing: 8) {
                    Text(selectedFilter == nil ? "No milestones yet" : "No \(selectedFilter?.displayName ?? "") milestones")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Tap + to create one")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(filteredMilestones) { milestone in
                        MilestoneRowView(
                            milestone: milestone,
                            progressItemId: progressItemId,
                            onDelete: {
                                Task {
                                    await deleteMilestone(milestone)
                                }
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: min(CGFloat(filteredMilestones.count) * 50, 240), maxHeight: 240)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
        .sheet(isPresented: $showCreateMilestone) {
            CreateMilestoneSheet(progressItemId: progressItemId) {
                Task {
                    await refreshMilestones()
                }
            }
        }
        .onAppear {
            if !listenerInitialized {
                setUpListener()
                listenerInitialized = true
            }
        }
        .onDisappear {
            listener?.remove()
            listenerInitialized = false
        }
        .onChange(of: progressItemId) { oldValue, newValue in
            listener?.remove()
            listenerInitialized = false
            milestones = []
            setUpListener()
            listenerInitialized = true
        }
    }

    private func setUpListener() {
        isLoading = true
        print("[MilestonesSection] Setting up listener for progress: \(progressItemId)")

        listener = milestoneService.setMilestonesListener(for: progressItemId) { fetchedMilestones in
            self.milestones = fetchedMilestones
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    private func refreshMilestones() async {
        isLoading = true
        do {
            let freshMilestones = try await milestoneService.fetchMilestones(for: progressItemId)
            await MainActor.run {
                self.milestones = freshMilestones
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func deleteMilestone(_ milestone: Milestone) async {
        do {
            try await milestoneService.deleteMilestone(milestone.id, for: progressItemId)
            await refreshMilestones()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct FilterButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundStyle(isSelected ? .white : .primary)
                .cornerRadius(4)
        }
    }
}

struct MilestoneRowView: View {
    let milestone: Milestone
    let progressItemId: String
    var onDelete: () -> Void = {}

    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Type indicator
                Image(systemName: milestone.type.iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(milestone.type.color)
                    .frame(width: 20)

                // Milestone name and progress
                VStack(alignment: .leading, spacing: 2) {
                    Text(milestone.name)
                        .font(.subheadline.weight(.semibold))
                    Text(milestone.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Type-specific display
                MilestoneProgressView(milestone: milestone)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(.systemBackground).opacity(0.5))
        .cornerRadius(6)
        .onTapGesture {
            isEditing = true
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Text("Delete")
            }
        }
        .sheet(isPresented: $isEditing) {
            EditMilestoneSheet(
                milestone: milestone,
                progressItemId: progressItemId
            ) {
                isEditing = false
            }
        }
    }
}

struct MilestoneProgressView: View {
    let milestone: Milestone

    var body: some View {
        switch milestone.type {
        case .count:
            HStack(spacing: 6) {
                Text("\(milestone.counter ?? 0)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Image(systemName: "number.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

        case .achievement:
            HStack(spacing: 4) {
                Image(systemName: (milestone.completed ?? false) ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle((milestone.completed ?? false) ? .green : .gray)
            }

        case .timeline:
            VStack(alignment: .trailing, spacing: 2) {
                if let date = milestone.targetDate {
                    let isOverdue = date < Date()
                    Text(formatDate(date))
                        .font(.caption)
                        .foregroundStyle(isOverdue ? .red : .secondary)
                    if isOverdue {
                        Text("Overdue")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Extensions for Display

extension MilestoneType {
    var displayName: String {
        switch self {
        case .count:
            return "Count"
        case .achievement:
            return "Achievement"
        case .timeline:
            return "Timeline"
        }
    }

    var iconName: String {
        switch self {
        case .count:
            return "number.circle.fill"
        case .achievement:
            return "checkmark.circle.fill"
        case .timeline:
            return "calendar.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .count:
            return .blue
        case .achievement:
            return .green
        case .timeline:
            return .orange
        }
    }
}

#Preview {
    MilestonesSection(progressItemId: "test123")
}
