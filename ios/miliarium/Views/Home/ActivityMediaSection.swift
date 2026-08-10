import SwiftUI
import PhotosUI
import AVKit
import FirebaseFirestore
internal import os

/// Form section that lists, uploads, and deletes media attachments
/// (photos + videos) on a single activity.
///
/// Designed to be dropped inside an existing `Form` in `EditActivitySheet`.
/// Owns its own listener on the activity's `media` subcollection so the
/// grid stays live during the edit session.
struct ActivityMediaSection: View {
    let progressItemId: String
    let activityId: String
    let uploadedBy: String?

    @State private var media: [ActivityMedia] = []
    @State private var listener: ListenerRegistration?
    @State private var selectedPickerItems: [PhotosPickerItem] = []
    @State private var uploadProgress = MediaUploadProgress()
    @State private var uploadTask: Task<Void, Never>?
    @State private var failedItems: [PhotosPickerItem] = []
    @State private var errorMessage: String?
    @State private var viewerMedia: ActivityMedia?
    @State private var pendingDelete: ActivityMedia?

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    /// Max media items per activity (also enforced by the backend on commit).
    private static let maxPerActivity = 20
    private var remainingSlots: Int { max(0, Self.maxPerActivity - media.count) }

    var body: some View {
        Section("Media") {
            if media.isEmpty && !uploadProgress.isUploading {
                Text("No photos or videos yet. Tap the button below to add some.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(media) { item in
                        MediaThumbnail(media: item)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture { viewerMedia = item }
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
            }

            if uploadProgress.isUploading {
                VStack(alignment: .leading, spacing: 6) {
                    if let label = uploadProgress.label {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: uploadProgress.fraction)
                    Button("Cancel", role: .cancel) { uploadTask?.cancel() }
                        .font(.caption)
                }
            } else if !failedItems.isEmpty {
                Button {
                    let retry = failedItems
                    uploadTask = Task { await uploadSelections(retry) }
                } label: {
                    Label("Retry \(failedItems.count) failed", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
            }

            PhotosPicker(
                selection: $selectedPickerItems,
                maxSelectionCount: max(1, remainingSlots),
                matching: .any(of: [.images, .videos])
            ) {
                Label("Add Photo or Video", systemImage: "photo.badge.plus")
            }
            .disabled(uploadProgress.isUploading || uploadedBy == nil || remainingSlots == 0)

            if remainingSlots == 0 {
                Text("This activity has the maximum of \(Self.maxPerActivity) files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { startListener() }
        .onDisappear {
            listener?.remove()
            listener = nil
        }
        .onChange(of: selectedPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            uploadTask = Task { await uploadSelections(newItems) }
        }
        .sheet(item: $viewerMedia) { item in
            MediaViewer(media: item)
        }
        .alert(
            "Delete media?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let item = pendingDelete {
                    Task { await delete(item) }
                }
                pendingDelete = nil
            }
        } message: {
            Text("This will permanently remove the file. This cannot be undone.")
        }
    }

    // MARK: - Listener

    private func startListener() {
        listener?.remove()
        listener = mediaService.setMediaListener(
            progressItemId: progressItemId,
            activityId: activityId
        ) { items in
            Task { @MainActor in
                self.media = items
            }
        }
    }

    // MARK: - Upload

    private func uploadSelections(_ items: [PhotosPickerItem]) async {
        guard let uploadedBy else {
            errorMessage = "You must be signed in to upload media."
            selectedPickerItems = []
            return
        }
        errorMessage = nil
        failedItems = []
        defer {
            uploadProgress.finish()
            selectedPickerItems = []
            uploadTask = nil
        }

        // Never exceed the per-activity cap, even across concurrent picks.
        let items = Array(items.prefix(remainingSlots))
        if items.isEmpty {
            errorMessage = "This activity already has the maximum of \(Self.maxPerActivity) files."
            return
        }

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            uploadProgress.begin(index: index + 1, total: items.count)
            do {
                if try await uploadOne(item, uploadedBy: uploadedBy) == false {
                    failedItems.append(item)
                    errorMessage = "Couldn't read one of the selected items."
                }
            } catch is CancellationError {
                break
            } catch {
                AppLogger.media.error("upload failed: \(error.localizedDescription)")
                failedItems.append(item)
                errorMessage = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    /// Uploads a single picker item, forwarding byte progress. Returns `false`
    /// if the bytes couldn't be loaded (skip silently); throws on upload errors.
    private func uploadOne(
        _ item: PhotosPickerItem,
        uploadedBy: String
    ) async throws -> Bool {
        let progress = uploadProgress
        let onProgress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in progress.fraction = fraction }
        }
        // Try image first.
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            _ = try await mediaService.uploadImage(
                image,
                progressItemId: progressItemId,
                activityId: activityId,
                uploadedBy: uploadedBy,
                onProgress: onProgress
            )
            return true
        }
        // Fall back to video transfer.
        if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
            _ = try await mediaService.uploadVideo(
                fileURL: movie.url,
                progressItemId: progressItemId,
                activityId: activityId,
                uploadedBy: uploadedBy,
                onProgress: onProgress
            )
            return true
        }
        return false
    }

    // MARK: - Delete

    private func delete(_ item: ActivityMedia) async {
        do {
            try await mediaService.deleteMedia(
                item,
                progressItemId: progressItemId,
                activityId: activityId
            )
        } catch {
            errorMessage = "Couldn't delete: \(error.localizedDescription)"
        }
    }
}

// MARK: - VideoTransferable

/// PhotosPicker hands video selections back as files in a temporary
/// location. This `Transferable` copies the file into our own tmp directory
/// so the URL stays valid long enough to upload.
private struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoTransferable(url: copy)
        }
    }
}

// MARK: - Thumbnail

/// Grid thumbnail that streams images directly via AsyncImage and shows a
/// play-overlay placeholder for videos. The full video stream is fetched
/// only when the user taps through to the viewer — keeps the grid cheap.
private struct MediaThumbnail: View {
    let media: ActivityMedia

    @State private var url: URL?

    var body: some View {
        ZStack {
            if media.type == .image, let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    @unknown default:
                        Color.gray.opacity(0.2)
                    }
                }
            } else if media.type == .video {
                ZStack {
                    Color.black.opacity(0.7)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .clipped()
        .task {
            if media.type == .image && url == nil {
                url = try? await mediaService.downloadURL(for: media.storagePath)
            }
        }
    }
}

// MARK: - Fullscreen Viewer

private struct MediaViewer: View {
    let media: ActivityMedia
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't load",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if let url {
                    switch media.type {
                    case .image:
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                ContentUnavailableView(
                                    "Couldn't load image",
                                    systemImage: "photo"
                                )
                            @unknown default:
                                EmptyView()
                            }
                        }
                    case .video:
                        VideoPlayer(player: AVPlayer(url: url))
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do {
                url = try await mediaService.downloadURL(for: media.storagePath)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
