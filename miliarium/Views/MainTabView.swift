import SwiftUI
import FirebaseAuth

struct MainTabView: View {
    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        TabView {
            HomeSectionView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            ExploreSectionView()
                .tabItem {
                    Label("Explore", systemImage: "map.fill")
                }

            ActivitySectionView()
                .tabItem {
                    Label("Activity", systemImage: "chart.line.uptrend.xyaxis")
                }

            ProfileSectionView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                }
        }
    }
}

// MARK: - Sections

private struct HomeSectionView: View {
    @Environment(ProgressStore.self) private var progressStore

    @State private var showCreateProgress = false
    @State private var showDeleteConfirmation = false
    @State private var progressToDelete: String?
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            Group {
                if progressStore.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if progressStore.progresses.isEmpty {
                    ContentUnavailableView {
                        Label("No progress yet", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text("Open the Progress menu above or tap below to create one.")
                    } actions: {
                        Button("Create progress") {
                            showCreateProgress = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    homeContent
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    progressMenu
                }
            }
            .sheet(isPresented: $showCreateProgress) {
                CreateProgressSheet { title in
                    await progressStore.createProgress(title: title)
                }
            }
            .overlay(alignment: .bottom) {
                if showDeleteConfirmation {
                    deleteConfirmationOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var progressMenu: some View {
        Menu {
            if progressStore.progresses.isEmpty {
                Button("Create progress…") {
                    showCreateProgress = true
                }
            } else {
                Picker(
                    "Progress",
                    selection: Binding(
                        get: { progressStore.selectedProgressId },
                        set: { progressStore.selectProgress(id: $0) }
                    )
                ) {
                    ForEach(progressStore.progresses) { item in
                        Text(item.title).tag(Optional.some(item.id))
                    }
                }
                Divider()
                Button("Create progress…") {
                    showCreateProgress = true
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(menuTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel("Choose progress")
    }

    private var menuTitle: String {
        if progressStore.progresses.isEmpty {
            return "Progress"
        }
        if let id = progressStore.selectedProgressId,
           let item = progressStore.progresses.first(where: { $0.id == id }) {
            return item.title
        }
        return "Progress"
    }

    @ViewBuilder
    private var homeContent: some View {
        if let id = progressStore.selectedProgressId,
           let item = progressStore.progresses.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.title)
                        .font(.title2.weight(.semibold))
                    if !item.content.summary.isEmpty {
                        Text(item.content.summary)
                            .font(.headline)
                    }
                    if !item.content.body.isEmpty {
                        Text(item.content.body)
                            .font(.body)
                    }
                    if item.content.summary.isEmpty && item.content.body.isEmpty {
                        Text("No content yet. Edit this progress to add a summary or notes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Delete button at the bottom
                    Button(role: .destructive) {
                        progressToDelete = item.id
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Delete Progress")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeleting)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            ContentUnavailableView(
                "Choose a progress",
                systemImage: "chevron.down.circle",
                description: Text("Pick one from the menu above.")
            )
        }
    }

    private var deleteConfirmationOverlay: some View {
        ZStack(alignment: .bottom) {
            // Semi-transparent background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        showDeleteConfirmation = false
                    }
                }

            // Confirmation dialog
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)

                    Text("Delete Progress?")
                        .font(.title3.weight(.semibold))

                    Text("This action cannot be undone. The progress item and all associated data will be permanently deleted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)

                Divider()

                // Buttons
                VStack(spacing: 0) {
                    Button(role: .destructive) {
                        deleteSelectedProgress()
                    } label: {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .tint(.red)
                            } else {
                                Image(systemName: "trash.fill")
                            }
                            Text("Delete")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .foregroundStyle(.red)
                    }
                    .disabled(isDeleting)

                    Divider()

                    Button("Cancel") {
                        withAnimation {
                            showDeleteConfirmation = false
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .foregroundStyle(.blue)
                }
            }
            .background(Color(.systemBackground))
            .cornerRadius(12, corners: [.topLeft, .topRight])
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func deleteSelectedProgress() {
        guard let progressId = progressToDelete else { return }

        isDeleting = true

        Task {
            let success = await progressStore.deleteProgress(progressId: progressId)

            await MainActor.run {
                isDeleting = false

                if success {
                    withAnimation {
                        showDeleteConfirmation = false
                    }
                    progressToDelete = nil
                }
                // Error message is stored in progressStore.errorMessage
            }
        }
    }
}

private struct ExploreSectionView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Explore",
                systemImage: "map.fill",
                description: Text("Browse and discover content here.")
            )
            .navigationTitle("Explore")
        }
    }
}

private struct ActivitySectionView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Activity",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("History and progress will appear here.")
            )
            .navigationTitle("Activity")
        }
    }
}

private struct ProfileSectionView: View {
    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let email = auth.user?.email {
                        LabeledContent("Signed in as", value: email)
                    } else {
                        Text("Signed in")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        auth.signOut()
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
}

// MARK: - Helper extension for rounded corners
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

#Preview {
    FirebasePreviewRoot {
        MainTabView()
            .environment(AuthViewModel())
            .environment(ProgressStore())
    }
}