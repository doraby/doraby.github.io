import SwiftUI
import AppKit

// MARK: - Main Dashboard

struct DashboardView: View {
    @ObservedObject var store: Store
    @State private var selectedTab = 0

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $selectedTab) {
                TasksTab(store: store)
                    .tabItem { Label("Tasks", systemImage: "list.bullet") }
                    .tag(0)
                ScreenshotsTab(store: store)
                    .tabItem { Label("Screenshots", systemImage: "camera") }
                    .tag(1)
                StatisticsTab(store: store)
                    .tabItem { Label("Statistics", systemImage: "chart.bar") }
                    .tag(2)
            }
        }
        .frame(minWidth: 700, minHeight: 520)
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

// MARK: - Tasks Tab

private struct TasksTab: View {
    @ObservedObject var store: Store

    private static let timeLabel: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        if store.entries.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("No activity recorded for this day")
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            List {
                ForEach(store.entries.sorted { $0.start > $1.start }) { entry in
                    TaskRow(entry: entry, store: store, timeLabel: Self.timeLabel)
                }
            }
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
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(colorForApp(entry.appName))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Task title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .onSubmit { save() }
                    Spacer()
                    Text(formatDuration(entry.duration))
                        .font(.callout.monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    Button(role: .destructive) { store.deleteEntry(entry) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                TextField("Add description\u{2026}", text: $details)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .onSubmit { save() }
                HStack(spacing: 4) {
                    Image(systemName: "app.fill")
                        .font(.caption2)
                    Text(entry.appName)
                    if !entry.domain.isEmpty {
                        Text("\u{00b7}")
                        Text(entry.domain)
                    }
                    Text("\u{00b7}")
                    Text("\(timeLabel.string(from: entry.start)) \u{2013} \(timeLabel.string(from: entry.end))")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
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

// MARK: - Screenshots Tab

private struct ScreenshotsTab: View {
    @ObservedObject var store: Store
    @State private var selectedScreenshot: ScreenshotItem?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280))]

    private static let stampLabel: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        if store.screenshots.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "camera.slash")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("No screenshots for this day")
                    .foregroundColor(.secondary)
                Text("Enable screenshots from the menu bar icon")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.screenshots) { item in
                        ScreenshotCard(item: item, timeLabel: Self.stampLabel)
                            .onTapGesture { selectedScreenshot = item }
                    }
                }
                .padding()
            }
            .sheet(item: $selectedScreenshot) { item in
                ScreenshotDetailView(item: item)
            }
        }
    }
}

private struct ScreenshotCard: View {
    let item: ScreenshotItem
    let timeLabel: DateFormatter
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(ProgressView().scaleEffect(0.7))
                }
            }
            .frame(height: 130)
            .clipped()
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

            Text(timeLabel.string(from: item.timestamp))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = NSImage(contentsOf: item.url) else { return }
            DispatchQueue.main.async { self.image = img }
        }
    }
}

private struct ScreenshotDetailView: View {
    let item: ScreenshotItem
    @Environment(\.dismiss) private var dismiss

    private static let fullLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Self.fullLabel.string(from: item.timestamp))
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            if let img = NSImage(contentsOf: item.url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
            } else {
                VStack {
                    Spacer()
                    Text("Unable to load image")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - Statistics Tab

private struct StatisticsTab: View {
    @ObservedObject var store: Store

    var body: some View {
        if store.entries.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "chart.bar")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("No data for this day")
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summaryCards

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Time per Application")
                            .font(.headline)
                        AppBarChart(appTotals: store.appTotals, dayTotal: store.dayTotal)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Activity Timeline")
                            .font(.headline)
                        ActivityTimeline(entries: store.entries)
                    }
                }
                .padding()
            }
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            SummaryCard(
                icon: "clock",
                value: formatDuration(store.dayTotal),
                label: "Tracked"
            )
            SummaryCard(
                icon: "list.bullet",
                value: "\(store.entries.count)",
                label: store.entries.count == 1 ? "Task" : "Tasks"
            )
            SummaryCard(
                icon: "app.badge",
                value: "\(Set(store.entries.map(\.appName)).count)",
                label: "Apps Used"
            )
        }
    }
}

private struct SummaryCard: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

private struct AppBarChart: View {
    let appTotals: [(app: String, total: TimeInterval)]
    let dayTotal: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(appTotals, id: \.app) { item in
                HStack(spacing: 8) {
                    Circle()
                        .fill(colorForApp(item.app))
                        .frame(width: 8, height: 8)
                    Text(item.app)
                        .font(.callout)
                        .frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        let fraction = dayTotal > 0 ? item.total / dayTotal : 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(colorForApp(item.app))
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: 20)
                    Text(formatDuration(item.total))
                        .font(.callout.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .frame(height: 24)
            }
        }
    }
}

private struct ActivityTimeline: View {
    let entries: [TaskEntry]

    private var dayRange: (start: Date, end: Date) {
        guard let earliest = entries.min(by: { $0.start < $1.start })?.start,
              let latest = entries.max(by: { $0.end < $1.end })?.end else {
            return (Date(), Date())
        }
        let cal = Calendar.current
        let startHour = cal.dateInterval(of: .hour, for: earliest)?.start ?? earliest
        var endHour = cal.dateInterval(of: .hour, for: latest)?.end ?? latest
        if endHour <= startHour { endHour = startHour.addingTimeInterval(3600) }
        return (startHour, endHour)
    }

    private static let hourLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ha"
        return f
    }()

    var body: some View {
        let range = dayRange
        let totalSeconds = range.end.timeIntervalSince(range.start)

        VStack(alignment: .leading, spacing: 4) {
            if totalSeconds > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.1))

                        ForEach(entries) { entry in
                            let startFrac = max(0, entry.start.timeIntervalSince(range.start) / totalSeconds)
                            let widthFrac = min(1 - startFrac, entry.duration / totalSeconds)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(colorForApp(entry.appName))
                                .frame(width: max(2, geo.size.width * widthFrac))
                                .offset(x: geo.size.width * startFrac)
                                .help("\(entry.title)\n\(formatDuration(entry.duration))")
                        }
                    }
                }
                .frame(height: 28)

                let hours = hourMarkers(from: range.start, to: range.end)
                HStack {
                    ForEach(Array(hours.enumerated()), id: \.offset) { _, date in
                        Text(Self.hourLabel.string(from: date).lowercased())
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if date != hours.last {
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func hourMarkers(from start: Date, to end: Date) -> [Date] {
        var marks: [Date] = []
        let cal = Calendar.current
        var current = start
        while current <= end {
            marks.append(current)
            guard let next = cal.date(byAdding: .hour, value: 1, to: current) else { break }
            current = next
        }
        if marks.count > 12 {
            let step = marks.count / 8
            marks = marks.enumerated().compactMap {
                $0.offset % step == 0 || $0.offset == marks.count - 1 ? $0.element : nil
            }
        }
        return marks
    }
}

// MARK: - Helpers

private let appColorPalette: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal,
    .indigo, .mint, .cyan, .brown, .red, .yellow
]

private func colorForApp(_ name: String) -> Color {
    let hash = name.utf8.reduce(0) { ($0 &+ Int($1)) &* 31 }
    return appColorPalette[abs(hash) % appColorPalette.count]
}
