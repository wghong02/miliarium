import SwiftUI
import MapKit

// MARK: - Search model

/// Thin SwiftUI-friendly wrapper around `MKLocalSearchCompleter`. Updates
/// `results` reactively as `query` changes, and resolves a chosen
/// completion to a full `MKMapItem` with coordinates.
@Observable
@MainActor
final class LocationSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()

    var query: String = "" {
        didSet { queryDidChange() }
    }
    var results: [MKLocalSearchCompletion] = []
    var errorMessage: String?

    override init() {
        super.init()
        completer.delegate = self
        // Apple Maps returns both POIs ("Joe's Coffee") and addresses
        // ("1 Apple Park Way"). Both are useful for an activity location.
        completer.resultTypes = [.address, .pointOfInterest]
    }

    private func queryDidChange() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        completer.queryFragment = trimmed
    }

    // MARK: MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let next = completer.results
        Task { @MainActor in
            self.results = next
            self.errorMessage = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.errorMessage = message
            self.results = []
        }
    }

    /// Resolves a completion to an `MKMapItem` (which carries the coordinate
    /// via `location.coordinate` on iOS 26+).
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> MKMapItem {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw NSError(
                domain: "LocationSearch",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't resolve that location."]
            )
        }
        return item
    }

    /// Extracts a coordinate from an `MKMapItem` using the iOS 26+
    /// non-optional `location` accessor (replaces the deprecated
    /// `placemark.coordinate`).
    static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        item.location.coordinate
    }

    /// Clears the query and any cached results. Called after a selection.
    func clear() {
        query = ""
        results = []
        errorMessage = nil
    }
}

// MARK: - View

/// SwiftUI search field that surfaces Apple Maps autocomplete suggestions
/// and writes the selected location's name + coordinates back through
/// bindings. Designed to live inside a `Form` section.
struct LocationSearchField: View {
    @Binding var locationName: String
    @Binding var latitude: Double?
    @Binding var longitude: Double?

    @State private var searchModel = LocationSearchModel()
    @State private var isResolving = false
    @State private var resolveError: String?

    /// Cap suggestion list so the Form section doesn't grow indefinitely.
    private let maxVisibleResults = 7

    var body: some View {
        Group {
            TextField("Search Apple Maps (e.g. Mount Everest)", text: $searchModel.query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if let resolveError {
                Text(resolveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if !searchModel.results.isEmpty {
                ForEach(searchModel.results.prefix(maxVisibleResults), id: \.self) { result in
                    Button {
                        selectResult(result)
                    } label: {
                        suggestionRow(for: result)
                    }
                    .buttonStyle(.plain)
                    .disabled(isResolving)
                }
            } else if let modelError = searchModel.errorMessage {
                Text(modelError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func suggestionRow(for result: MKLocalSearchCompletion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isResolving ? "hourglass" : "mappin.circle")
                .foregroundStyle(.blue)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }

    private func selectResult(_ result: MKLocalSearchCompletion) {
        isResolving = true
        resolveError = nil
        Task {
            do {
                let item = try await searchModel.resolve(result)
                let coord = LocationSearchModel.coordinate(of: item)
                locationName = item.name ?? result.title
                latitude = coord.latitude
                longitude = coord.longitude
                searchModel.clear()
                isResolving = false
            } catch {
                resolveError = error.localizedDescription
                isResolving = false
            }
        }
    }
}
