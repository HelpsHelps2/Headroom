import SwiftUI
import HeadroomCore

struct WorktreesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var choosingRepository = false

    private var rows: [WorktreeGroup] {
        model.repositoryGroups.filter { group in
            switch model.worktreeFilter {
            case .stale: group.stale
            case .kept: !group.stale
            case .all: true
            }
        }
    }

    /// Rows split by repository when showing all of them, so each gets its own trunk.
    private var sections: [(repository: String?, rows: [WorktreeGroup])] {
        guard model.selectedRepository == nil, model.repositories.count > 1 else { return [(nil, rows)] }
        var sections: [(repository: String?, rows: [WorktreeGroup])] = []
        for row in rows {
            if sections.last?.repository == row.repository { sections[sections.count - 1].rows.append(row) }
            else { sections.append((row.repository, [row])) }
        }
        return sections
    }

    private var repositoryTitle: String {
        model.selectedRepository ?? (model.repositories.isEmpty ? "No repositories" : "All repositories")
    }

    var body: some View {
        @Bindable var model = model
        let all = model.repositoryGroups
        let stale = all.filter(\.stale)
        let chosen = model.selectedGroups
        VStack(spacing: 0) {
            TopBar { ScanButton() } title: { Brand() } trailing: { Color.clear.frame(width: 24) }
            Tabs(selection: $model.tab)
            HStack {
                Button { choosingRepository = true } label: {
                    HStack(spacing: 6) {
                        Text(repositoryTitle).font(.sans(15, .semibold)).tracking(-0.2).foregroundStyle(theme.ink)
                        Image(systemName: "chevron.down").font(.sans(10, .semibold)).foregroundStyle(theme.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .disabled(model.repositories.count < 2)
                .popover(isPresented: $choosingRepository, arrowEdge: .bottom) { repositoryList }
                Spacer()
                Text("\(all.count) trees · \(Format.bytes(all.reduce(0) { $0 + $1.bytes }))").font(.mono(11, .medium)).foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 14).padding(.top, 14)
            HStack(spacing: 14) {
                filter(.all, all.count)
                filter(.stale, stale.count)
                filter(.kept, all.count - stale.count)
                Spacer()
                if !chosen.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.15)) { model.selected = [] } } label: {
                        Text("Clear \(chosen.count)").font(.sans(11.5, .medium)).foregroundStyle(theme.accent).padding(.bottom, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear the selection")
                }
            }
            .padding(.horizontal, 14).padding(.top, 10)
            .hairline(.bottom)
            if rows.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let largest = rows.map(\.bytes).max() ?? 1
                        ForEach(sections, id: \.repository) { section in
                            if let repository = section.repository { sectionHeader(repository, section.rows) }
                            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, group in
                                GraphRow(group: group, first: index == 0, last: index == section.rows.count - 1, largest: largest) { range in
                                    withAnimation(.easeOut(duration: 0.12)) { model.toggleSelected(group, range: range, in: rows) }
                                }
                            }
                        }
                    }
                    .padding(.top, 2).padding(.bottom, 24)
                }
                .scrollIndicators(.never)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
            Group {
                if chosen.isEmpty {
                    PrimaryButton(title: stale.isEmpty ? "Nothing stale here" : "Review \(stale.count) stale \(stale.count == 1 ? "worktree" : "worktrees")",
                                  detail: stale.isEmpty ? nil : Format.bytes(stale.reduce(0) { $0 + $1.reclaimable })) {
                        model.openReview(stale.flatMap(\.artifacts))
                    }
                    .disabled(stale.isEmpty)
                } else {
                    PrimaryButton(title: "Review \(chosen.count) selected",
                                  detail: Format.bytes(chosen.flatMap(\.removable).reduce(0) { $0 + $1.bytes })) {
                        model.reviewSelection()
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
            .hairline(.top)
        }
    }

    private func sectionHeader(_ repository: String, _ rows: [WorktreeGroup]) -> some View {
        HStack(spacing: 6) {
            Text(repository).font(.sans(11.5, .semibold)).foregroundStyle(theme.ink)
            Text("\(rows.count) · \(Format.bytes(rows.reduce(0) { $0 + $1.bytes }))").font(.mono(10.5)).foregroundStyle(theme.dim)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
    }

    private func filter(_ value: WorktreeFilter, _ count: Int) -> some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.worktreeFilter = value } } label: {
            HStack(spacing: 4) {
                Text(value.rawValue).foregroundStyle(model.worktreeFilter == value ? theme.ink : theme.muted)
                Text("\(count)").font(.mono(11)).foregroundStyle(theme.dim)
            }
            .font(.sans(11.5, .medium))
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                if model.worktreeFilter == value { Rectangle().fill(theme.accent).frame(height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: model.worktreeFilter == .stale ? "checkmark.circle" : "tray").font(.sans(22)).foregroundStyle(theme.dim)
            Text(model.repositories.isEmpty ? "No build output found yet" : model.worktreeFilter == .stale ? "Nothing stale in \(model.selectedRepository ?? "any repository")" : "Nothing to show")
                .font(.sans(13, .medium))
            Text(model.worktreeFilter == .stale ? "Worktrees become stale after \(Format.hours(model.preferences.keepHours)) without builds or open files. Check a recent one in All to clean it now." : "Kept worktrees appear here with the reason.")
                .font(.sans(11.5)).foregroundStyle(theme.muted).multilineTextAlignment(.center).frame(maxWidth: 240)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var repositoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            repositoryItem(nil, "All repositories", model.repositories.reduce(0) { $0 + $1.trees }, model.repositories.reduce(0) { $0 + $1.bytes })
            Divider().padding(.vertical, 4)
            ForEach(model.repositories, id: \.name) { repository in
                repositoryItem(repository.name, repository.name, repository.trees, repository.bytes)
            }
        }
        .padding(6).frame(minWidth: 220)
    }

    private func repositoryItem(_ name: String?, _ title: String, _ trees: Int, _ bytes: Int64) -> some View {
        Button {
            model.repository = name; choosingRepository = false
        } label: {
            HStack {
                Image(systemName: "checkmark").opacity(name == model.selectedRepository ? 1 : 0).font(.sans(10, .bold))
                Text(title).font(.sans(12.5, .medium))
                Spacer(minLength: 16)
                Text("\(trees) · \(Format.bytes(bytes))").font(.mono(11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GraphRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let group: WorktreeGroup
    let first: Bool
    let last: Bool
    let largest: Int64
    /// Toggles the checkbox; true when Shift extends the selection.
    let toggle: (Bool) -> Void

    private var checked: Bool { model.selected.contains(group.top) && group.selectable }

    private var detail: String {
        if group.waiting { return checked ? "built recently · skips the \(Format.hours(model.preferences.keepHours)) wait" : Reason.short(group.keptReason ?? "Kept") }
        if !group.stale { return Reason.short(group.keptReason ?? "Kept") }
        var parts = ["idle " + Format.age(group.lastWrite)]
        if let changed = group.info?.changedFiles { parts.append(changed == 0 ? "clean" : "\(changed) changed") }
        if group.artifacts.count > 1 { parts.append("\(group.artifacts.count) folders") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 38, height: 45)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.mono(12, .medium)).foregroundStyle(group.selectable ? theme.ink : theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 3) {
                    if group.waiting { Image(systemName: "hourglass").font(.sans(8.5)) }
                    else if !group.stale { Image(systemName: "lock.fill").font(.sans(8)) }
                    Text(detail).lineLimit(1)
                }
                .font(.sans(11)).foregroundStyle(checked && group.waiting ? theme.accent : group.stale ? theme.muted : theme.ink.opacity(0.7))
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Format.bytes(group.bytes)).font(.mono(12, .medium)).foregroundStyle(group.selectable ? theme.ink : theme.dim).monospacedDigit()
                Capsule().fill(theme.track).frame(width: 50, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(group.stale || checked ? theme.accent : theme.used)
                            .frame(width: max(3, 50 * CGFloat(Double(group.bytes) / Double(max(largest, 1)))), height: 3)
                    }
            }
        }
        .padding(.trailing, 14)
        .background(checked ? theme.accentSoft : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if group.selectable { toggle(NSEvent.modifierFlags.contains(.shift)) } }
        .help(group.selectable ? (checked ? "Deselect" : "Select to clean") + " · Shift-click selects a range" : group.artifacts.flatMap(\.reasons).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(group.selectable ? .isButton : [])
        .accessibilityValue(group.selectable ? (checked ? "selected" : "not selected") : "kept")
        .contextMenu {
            if group.selectable {
                Button(checked ? "Deselect" : "Select") { toggle(false) }
                Button(group.waiting ? "Clean Now…" : "Review This Worktree") { model.openReview(group.removable, skippingWait: true) }
                Divider()
            }
            if let process = group.process {
                Button("Quit \(process.name) (pid \(process.pid))…") { model.quit(process) }.disabled(model.demo)
            }
            Button("Reveal in Finder") { model.reveal(group.top) }
            Button(model.preferences.pinned.contains(group.top) ? "Stop Keeping" : "Always Keep") { model.togglePin(group) }
                .disabled(model.demo)
        }
    }

    private var rail: some View {
        Canvas { context, size in
            let x: CGFloat = 12, mid = size.height / 2
            let main = group.info?.isMain ?? false
            // The trunk starts at the main checkout's node; without one it runs in from the top, like the branch.
            var trunk = Path()
            trunk.move(to: CGPoint(x: x, y: first && main ? mid : 0))
            trunk.addLine(to: CGPoint(x: x, y: last ? mid : size.height))
            context.stroke(trunk, with: .color(theme.used), lineWidth: 1.5)
            if main && !group.selectable {
                context.fill(Path(ellipseIn: CGRect(x: x - 4.5, y: mid - 4.5, width: 9, height: 9)), with: .color(theme.ink))
                return
            }
            let tip: CGFloat = group.selectable ? 21 : 24
            if !main {
                var branch = Path()
                branch.move(to: CGPoint(x: x, y: 5))
                branch.addCurve(to: CGPoint(x: tip, y: mid), control1: CGPoint(x: x, y: 17), control2: CGPoint(x: tip, y: 13))
                context.stroke(branch, with: .color(group.stale || checked ? theme.accent : theme.used), lineWidth: 1.5)
            }
            guard group.selectable else {
                context.fill(Path(ellipseIn: CGRect(x: 24 - 4, y: mid - 4, width: 8, height: 8)), with: .color(theme.used))
                return
            }
            // The branch ends in this worktree's checkbox.
            let box = CGRect(x: (main ? x : tip + 6) - 6.5, y: mid - 6.5, width: 13, height: 13)
            let shape = Path(roundedRect: box, cornerRadius: 3.5)
            if checked {
                context.fill(shape, with: .color(theme.accent))
                var tick = Path()
                tick.move(to: CGPoint(x: box.minX + 3.2, y: box.midY + 0.2))
                tick.addLine(to: CGPoint(x: box.minX + 5.6, y: box.midY + 2.6))
                tick.addLine(to: CGPoint(x: box.maxX - 3, y: box.midY - 2.6))
                context.stroke(tick, with: .color(theme.accentInk), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            } else {
                context.fill(shape, with: .color(theme.dark ? Color(hex: 0x15171B) : Color(hex: 0xF7F7F6)))
                context.stroke(shape, with: .color(group.stale ? theme.accent : theme.dim), lineWidth: 1.4)
            }
        }
    }
}
