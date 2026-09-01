import SwiftUI

struct DeviceUsageView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedDeviceID: String?
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)

    private var filtered: [DeviceUsageDay] { store.deviceUsageDays.filter { selectedDeviceID == nil || $0.deviceId == selectedDeviceID } }
    private var dayTotals: [Date: Int64] {
        Dictionary(grouping: filtered, by: { Calendar.current.startOfDay(for: $0.date) }).mapValues { $0.reduce(0) { $0 + $1.tokens.totalTokens } }
    }
    private var selectedRows: [DeviceUsageDay] { filtered.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }.sorted { $0.tokens.totalTokens > $1.tokens.totalTokens } }
    private var selectedTotal: Int64 { selectedRows.reduce(0) { $0 + $1.tokens.totalTokens } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                deviceScope
                summary
                Text("Token activity").font(.title3.weight(.bold)).padding(.top, 4)
                TokenHeatmap(days: dayTotals, selectedDate: $selectedDate)
                selectedDay
            }
            .padding(.horizontal).padding(.bottom)
        }
        .background(Theme.canvas)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.large)
    }

    private var deviceScope: some View {
        Menu {
            Button("All devices") { selectedDeviceID = nil }
            ForEach(store.devices) { device in Button(device.name) { selectedDeviceID = device.id } }
        } label: {
            HStack {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(selectedDeviceID.flatMap { id in store.devices.first(where: { $0.id == id })?.name } ?? "All devices").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer(); Text(selectedDeviceID == nil ? "\(store.devices.count)" : "1").font(.caption).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, 14).frame(minHeight: 46).card()
        }.buttonStyle(.plain).accessibilityLabel("Device")
    }

    private var summary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) { Text("Today's tokens").font(.caption).foregroundStyle(.secondary); Text(TokenFormat.compact(dayTotals[Calendar.current.startOfDay(for: .now)] ?? 0)).font(.title2.weight(.bold)).monospacedDigit() }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) { Text("This month").font(.caption).foregroundStyle(.secondary); Text(TokenFormat.compact(monthTotal)).font(.headline.weight(.bold)).foregroundStyle(Theme.cobalt).monospacedDigit() }
        }.padding(14).frame(minHeight: 76).card()
    }

    private var monthTotal: Int64 {
        guard let interval = Calendar.current.dateInterval(of: .month, for: .now) else { return 0 }
        return dayTotals.filter { interval.contains($0.key) }.values.reduce(0, +)
    }

    private var selectedDay: some View {
        VStack(spacing: 0) {
            HStack { Text(selectedDate, format: .dateTime.month().day()).font(.headline); Spacer(); Text("\(TokenFormat.compact(selectedTotal)) tokens").font(.caption.weight(.bold)).foregroundStyle(Theme.cobalt) }.padding(.bottom, 10)
            Divider()
            if selectedRows.isEmpty { Text("No device token activity for this day").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 18) }
            ForEach(selectedRows) { row in
                HStack { Circle().fill(color(for: row.deviceId)).frame(width: 7, height: 7); Text(row.deviceName).font(.subheadline); Spacer(); Text("\(TokenFormat.compact(row.tokens.totalTokens)) tokens").font(.caption.weight(.medium)).foregroundStyle(Theme.cobalt).monospacedDigit() }.padding(.vertical, 9)
                if row.id != selectedRows.last?.id { Divider().padding(.leading, 18) }
            }
        }.padding(14).card()
    }

    private func color(for deviceID: String) -> Color { let palette: [Color] = [.green, Theme.cobalt, .gray, .orange]; return palette[abs(deviceID.hashValue) % palette.count] }
}

private struct TokenHeatmap: View {
    let days: [Date: Int64]
    @Binding var selectedDate: Date
    private let calendar = Calendar.current
    private let cell: CGFloat = 12
    private let gap: CGFloat = 4

    private var start: Date {
        let earliest = days.keys.min() ?? calendar.date(byAdding: .day, value: -364, to: .now)!
        return calendar.dateInterval(of: .weekOfYear, for: earliest)?.start ?? earliest
    }
    private var end: Date { calendar.dateInterval(of: .weekOfYear, for: .now)?.end ?? .now }
    private var weeks: [[Date]] {
        var result: [[Date]] = [], current = start
        while current < end {
            result.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: current) })
            current = calendar.date(byAdding: .day, value: 7, to: current)!
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(week, id: \.self) { date in cellView(date) }
                        }
                    }
                }
                monthLabels
            }.padding(14)
        }
        .defaultScrollAnchor(.trailing)
        .frame(height: 190).background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityLabel("Token activity heatmap, scroll horizontally")
    }

    private func cellView(_ date: Date) -> some View {
        let value = days[calendar.startOfDay(for: date)] ?? 0
        let level = UsageIntensity.level(for: value, among: Array(days.values))
        return Button { selectedDate = calendar.startOfDay(for: date) } label: {
            RoundedRectangle(cornerRadius: 3).fill(heatColor(level)).frame(width: cell, height: cell)
                .overlay { if calendar.isDate(date, inSameDayAs: selectedDate) { RoundedRectangle(cornerRadius: 3).stroke(Theme.cobalt, lineWidth: 2) } }
        }.buttonStyle(.plain).accessibilityLabel("\(date.formatted(.dateTime.month().day()))，\(value) tokens")
    }

    private var monthLabels: some View {
        HStack(spacing: gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                let date = week[0]
                let startsMonth = index == 0 || calendar.component(.month, from: date) != calendar.component(.month, from: weeks[index - 1][0])
                Text(startsMonth ? String(format: "%02d", calendar.component(.month, from: date)) : "")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: cell, alignment: .leading)
            }
        }
    }

    private func heatColor(_ level: Int) -> Color {
        switch level { case 1: return Color(light: 0xD8E6FF, dark: 0x123A68); case 2: return Color(light: 0xAFCBFF, dark: 0x15549D); case 3: return Color(light: 0x73A5FF, dark: 0x196BC9); case 4: return Color(light: 0x2456E8, dark: 0x1684E8); default: return Color(light: 0xE9EBEF, dark: 0x242529) }
    }
}

enum TokenFormat {
    static func compact(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
