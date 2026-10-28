import SwiftUI
import HeadroomCore

struct SweepView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let sweep = model.sweep ?? SweepState(candidates: [])
        let cleaned = sweep.entries.values.filter { $0.outcome == "Cleaned" }.count
        let skipped = sweep.entries.count - cleaned
        VStack(spacing: 0) {
            TopBar { Color.clear.frame(width: 24) } title: { Brand() } trailing: { Color.clear.frame(width: 24) }
            VStack(spacing: 5) {
                StatusPill(text: pill(sweep), calm: sweep.finished)
                Text(sweep.finished ? "\(cleaned) cleaned · \(skipped) skipped" : "stale build output only")
                    .font(.mono(12.5)).foregroundStyle(theme.muted)
            }
            .padding(.top, 22)
            DiskRing(capacity: model.inventory.capacity, available: model.inventory.available + sweep.freed,
                     highlight: max(sweep.total - sweep.freed - sweep.skippedBytes, 0), tickSpeed: 12) {
                CoreDisc {
                    VStack(spacing: 4) {
                        BigBytes(bytes: sweep.freed)
                        Text("of \(Format.bytes(sweep.total)) freed").font(.mono(11)).foregroundStyle(theme.muted)
                    }
                }
            }
            .padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sweep.candidates) { candidate in row(candidate, sweep).id(candidate.path) }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .onChange(of: sweep.current) { _, current in
                    guard let current else { return }
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .padding(.top, 14)
            Group {
                if sweep.finished {
                    PrimaryButton(title: "Done", detail: Format.bytes(sweep.freed)) { model.closeSweep() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    GhostButton(title: sweep.stopping ? "Stopping after this folder…" : "Stop after this folder") { model.stopSweep() }
                        .disabled(sweep.stopping)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private func pill(_ sweep: SweepState) -> String {
        if sweep.finished { return sweep.stopping ? "Stopped" : "Done" }
        if sweep.stopping { return "Stopping" }
        return "Sweeping · \(min(sweep.done + 1, sweep.candidates.count)) of \(sweep.candidates.count)"
    }

    @ViewBuilder private func row(_ candidate: Artifact, _ sweep: SweepState) -> some View {
        let entry = sweep.entries[candidate.path]
        let current = sweep.current == candidate.path
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Group {
                    if let entry {
                        Image(systemName: entry.outcome == "Cleaned" ? "checkmark" : "minus").font(.sans(9.5, .bold))
                    } else if current {
                        PulseDot()
                    } else { Color.clear }
                }
                .frame(width: 16)
                Text(Format.compact(candidate.bytes)).frame(width: 44, alignment: .trailing).monospacedDigit()
                Text(candidate.label).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            .frame(height: 21)
            .padding(.horizontal, current ? 6 : 0)
            .background(current ? theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, current ? -6 : 0)
            if let entry, entry.outcome != "Cleaned" {
                Text("skipped: " + Reason.short(entry.detail)).italic().foregroundStyle(theme.dim)
                    .lineLimit(1).padding(.leading, 72).frame(height: 18)
            }
        }
        .font(.mono(10.5))
        .foregroundStyle(entry == nil ? (current ? theme.ink : theme.dim) : entry?.outcome == "Cleaned" ? theme.muted : theme.accent)
    }
}

struct PulseDot: View {
    @Environment(\.theme) private var theme
    @State private var on = false
    var body: some View {
        Circle().fill(theme.accent).frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.35).scaleEffect(on ? 1.2 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true } }
    }
}
