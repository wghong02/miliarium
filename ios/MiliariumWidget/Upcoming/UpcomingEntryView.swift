import SwiftUI
import WidgetKit

/// Renders one `UpcomingEntry` in a `systemSmall` widget. Lays out a tiny
/// header + up to 3 stacked rows; falls back to an empty-state message
/// when the snapshot has no future items.
struct UpcomingEntryView: View {
    let entry: UpcomingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if entry.items.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing scheduled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.items.prefix(3)) { item in
                    UpcomingRow(item: item)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
            Text("Upcoming")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// Compact two-line row: title + relative time.
private struct UpcomingRow: View {
    let item: UpcomingSnapshot.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 3) {
                // `style: .relative` renders "in 1 hr" / "in 3 days" and
                // updates automatically as the date approaches.
                Text(item.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.hasLocation {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
