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
    @State private var isEnqueuing = false
    @State private var errorMessage: String?
    @State private var viewerMedia: ActivityMedia?
    @State private var pendingDelete: ActivityMedia?

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    /// In-flight uploads for this activity.
    private var pendingUploads: [UploadCenter.PendingUpload] {
        uploadCenter.uploads(forActivity: activityId)
    }

    /// Max media items per activity (also enforced by the backend on commit).
    private static let maxPerActivity = 20
    private var remainingSlots: Int {
        max(0, Self.maxPerActivity - media.count - pendingUploads.count)
    }

    var body: some View {
        Section("Media") {
            if media.isEmpty && pendingUploads.isEmpty {
                Text("No photos or videos yet. Tap the button below to add some.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    // In-flight uploads first (newest), with live progress.
                    ForEach(pendingUploads) { upload in
                        PendingUploadCell(upload: upload) {
                            uploadCenter.remove(mediaId: upload.id)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
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

            PhotosPicker(
                selection: $selectedPickerItems,
                maxSelectionCount: max(1, remainingSlots),
                matching: .any(of: [.images, .videos])
            ) {
                Label("Add Photo or Video", systemImage: "photo.badge.plus")
            }
            .disabled(isEnqueuing || uploadedBy == nil || remainingSlots == 0)

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
            Task { await enqueueSelections(newItems) }
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

    /// Prepares each pick and hands it to the background upload session. Returns
    /// quickly; the transfer continues in the background and is shown live via
    /// `uploadCenter`.
    private func enqueueSelections(_ items: [PhotosPickerItem]) async {
        guard let uploadedBy else {
            errorMessage = "You must be signed in to upload media."
            selectedPickerItems = []
            return
        }
        errorMessage = nil
        isEnqueuing = true
        defer {
            isEnqueuing = false
            selectedPickerItems = []
        }

        // Never exceed the per-activity cap (committed + in-flight).
        let items = Array(items.prefix(remainingSlots))
        if items.isEmpty {
            errorMessage = "This activity already has the maximum of \(Self.maxPerActivity) files."
            return
        }

        for item in items {
            do {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    try await mediaService.enqueueUpload(
                        image: image,
                        progressItemId: progressItemId,
                        activityId: activityId,
                        uploadedBy: uploadedBy
                    )
                } else if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
                    try await mediaService.enqueueUpload(
                        videoFileURL: movie.url,
                        progressItemId: progressItemId,
                        activityId: activityId,
                        uploadedBy: uploadedBy
                    )
                } else {
                    errorMessage = "Couldn't read one of the selected items."
                }
            } catch {
                AppLogger.media.error("enqueue failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
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

// MARK: - Pending upload cell

/// Placeholder shown for an in-flight upload: the local preview dimmed behind a
/// determinate progress ring, or a tap-to-dismiss error state on failure.
private struct PendingUploadCell: View {
    let upload: UploadCenter.PendingUpload
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            if let preview = upload.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
            Color.black.opacity(0.35)

            if upload.failed {
                Button(action: onDismiss) {
                    VStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                        Text("Failed").font(.caption2)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.35), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, upload.fraction))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 34, height: 34)
                .animation(.easeInOut(duration: 0.15), value: upload.fraction)
            }
        }
        .clipped()
    }
}

// MARK: - Thumbnail

/// Grid thumbnail that streams the small thumbnail object directly via
/// AsyncImage (falling back to the full object if no thumbnail was stored).
/// This makes the grid cheap even for videos, which get a real frame thumbnail.
private struct MediaThumbnail: View {
    let media: ActivityMedia

    @State private var url: URL?

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        Color.gray.opacity(0.2)
                    }
                }
            } else {
                placeholder
            }

            // Play badge over video thumbnails.
            if media.type == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .clipped()
        .task {
            if url == nil {
                // Prefer the dedicated thumbnail object; fall back to the full
                // file (older items may not have a thumbnail).
                let path = media.thumbnailStoragePath ?? media.storagePath
                url = try? await mediaService.downloadURL(for: path)
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Image(systemName: media.type == .video ? "video" : "photo")
                .foregroundStyle(.secondary)
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
