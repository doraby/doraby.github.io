import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: Store

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()
    private static let timeLabel: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.entries.isEmpty {
                Spacer()
                Text("No activity recorded for this day yet.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    Section("Tasks") {
                        ForEach(store.entries.sorted { $0.start > $1.start }) { entry in
                            TaskRow(entry: entry, store: store, timeLabel: Self.timeLabel)
                        }
                    }
                    Section("Time per application") {
                        ForEach(store.appTotals, id: \.app) { item in
                            HStack {
                                Text(item.app)
                                Spacer()
                                Text(formatDuration(item.total))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Button { shift(by: -1) } label: { Image(systemName: "chevron.left") }
            DatePicker("", selection: $store.selectedDay, displayedComponents: .date)
                .labelsHidden()
            Button { shift(by: 1) } label: { Image(systemName: "chevron.right") }
            Text(Self.dayLabel.string(from: store.selectedDay))
                .font(.headline)
            Spacer()
            Text("Total: \(formatDuration(store.dayTotal))")
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(10)
    }

    private func shift(by days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: store.selectedDay) {
            store.selectedDay = d
        }
    }
}

private struct TaskRow: View {
    let entry: TaskEntry
    let store: Store
    let timeLabel: DateFormatter

    @State private var title: String = ""
    @State private var details: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Task title", text: $title, onCommit: save)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                Spacer()
                Text(formatDuration(entry.duration))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Button(role: .destructive) { store.deleteEntry(entry) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextField("Description…", text: $details, onCommit: save)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundColor(.secondary)
            Text("\(entry.appName) · \(timeLabel.string(from: entry.start))–\(timeLabel.string(from: entry.end))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .onAppear {
            title = entry.title
            details = entry.details
        }
    }

    private func save() {
        var updated = entry
        updated.title = title
        updated.details = details
        store.updateEntry(updated)
    }
}
