import SwiftUI
import Charts
import HeadroomCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var expanded: String?

    private var monthRuns: [SweepRun] {
        let calendar = Calendar.current
        return model.runs.filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
    }

    var body: some View {
        @Bindable var model = model
        let month = monthRuns
        VStack(spacing: 0) {
            TopBar { Color.clear.frame(width: 24) } title: { Brand() } trailing: { Color.clear.frame(width: 24) }
            Tabs(selection: $model.tab)
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Reclaimed in " + Date().formatted(.dateTime.month(.wide)))
                BigBytes(bytes: month.reduce(0) { $0 + $1.bytes }, size: 38).padding(.top, 8)
                Text("\(month.count) \(month.count == 1 ? "sweep" : "sweeps") · \(month.reduce(0) { $0 + $1.skipped.count }) folders skipped as active")
                    .font(.mono(11.5)).foregroundStyle(theme.muted).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 16)
            chart.padding(.horizontal, 14).padding(.top, 14)
            if model.runs.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No sweeps yet").font(.sans(13, .medium))
                    Text("Reclaimed space, and anything skipped because it became active, shows up here.")
                        .font(.sans(11.5)).foregroundStyle(theme.muted).multilineTextAlignment(.center).frame(maxWidth: 250)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.runs) { run in row(run) }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 16)
                }
                .scrollIndicators(.never)
                .padding(.top, 6)
            }
        }
    }

    private var chart: some View {
        let samples = model.space
        let now = model.inventory.available
        let start = samples.first?.date ?? Date().addingTimeInterval(-14 * 86400)
        let sweeps = model.runs.filter { $0.date >= start && $0.bytes > 0 }
        return VStack(spacing: 0) {
            HStack {
                Text("free space · 14 days").foregroundStyle(theme.muted)
                Spacer()
                if now > 0 { Text("\(Format.bytes(now)) now").foregroundStyle(theme.ink) }
            }
            .font(.mono(10.5, .medium))
            if samples.count < 2 {
                Text("Free space is recorded with each scan.").font(.sans(11)).foregroundStyle(theme.dim)
                    .frame(maxWidth: .infinity, minHeight: 66)
            } else {
                Chart {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        LineMark(x: .value("Date", sample.date), y: .value("Free", Double(sample.available) / 1e9))
                            .foregroundStyle(theme.muted).lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                            .interpolationMethod(.linear)
                    }
                    ForEach(sweeps) { run in
                        RuleMark(x: .value("Sweep", run.date))
                            .foregroundStyle(theme.accent.opacity(run.automatic ? 0.55 : 0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2.5]))
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: 0...max(Double(samples.map(\.available).max() ?? 1) / 1e9 * 1.08, 1))
                .frame(height: 66).padding(.top, 10)
            }
            HStack {
                Text(start.formatted(.dateTime.month(.abbreviated).day()))
                Spacer()
                HStack(spacing: 5) {
                    Rectangle().fill(theme.accent).frame(width: 1, height: 9)
                    Text("sweep")
                }
                .foregroundStyle(theme.accent)
                Spacer()
                Text(Date().formatted(.dateTime.month(.abbreviated).day()))
            }
            .font(.mono(10)).foregroundStyle(theme.dim).padding(.top, 6)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.surfaceStroke, lineWidth: 1))
    }

    private func title(_ run: SweepRun) -> String {
        let calendar = Calendar.current
        let time = run.date.formatted(date: .omitted, time: .shortened)
        let day = calendar.isDateInToday(run.date) ? "Today" : calendar.isDateInYesterday(run.date) ? "Yesterday" : run.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day), \(time) · \(run.automatic ? "automatic" : "manual")"
    }

    private func row(_ run: SweepRun) -> some View {
        let open = expanded == run.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { expanded = open ? nil : run.id }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(run)).font(.sans(12, .medium)).foregroundStyle(theme.ink)
                        Text("\(run.cleaned.count) folders · \(run.skipped.count) skipped\(run.skipped.isEmpty ? "" : ", active")")
                            .font(.sans(11)).foregroundStyle(run.skipped.isEmpty ? theme.muted : theme.accent)
                    }
                    Spacer()
                    Text(Format.bytes(run.bytes)).font(.mono(12, .medium)).monospacedDigit()
                    Image(systemName: "chevron.right").font(.sans(9, .semibold)).foregroundStyle(theme.dim)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(run.entries.sorted { $0.bytes > $1.bytes }) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: entry.outcome == "Cleaned" ? "checkmark" : "minus").font(.sans(9, .bold))
                                .foregroundStyle(entry.outcome == "Cleaned" ? theme.muted : theme.accent).frame(width: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Format.home(entry.path)).lineLimit(1).truncationMode(.head)
                                if entry.outcome != "Cleaned" {
                                    Text(Reason.short(entry.detail)).foregroundStyle(theme.dim).italic()
                                }
                            }
                            Spacer(minLength: 4)
                            if entry.bytes > 0 { Text(Format.compact(entry.bytes)).foregroundStyle(theme.muted) }
                        }
                        .font(.mono(10.5))
                    }
                }
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .hairline(.bottom)
    }
}
