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

    var body: some View {
        @Bindable var model = model
        let all = model.repositoryGroups
        let stale = all.filter(\.stale)
        VStack(spacing: 0) {
            TopBar { Color.clear.frame(width: 24) } title: { Brand() } trailing: {
                IconButton(symbol: "arrow.clockwise", help: "Scan now") { Task { await model.scan() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.scanning || model.demo)
            }
            Tabs(selection: $model.tab)
            HStack {
                Button { choosingRepository = true } label: {
                    HStack(spacing: 6) {
                        Text(model.selectedRepository ?? "No repositories").font(.sans(15, .semibold)).tracking(-0.2).foregroundStyle(theme.ink)
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
                filter(.stale, stale.count)
                filter(.kept, all.count - stale.count)
                filter(.all, all.count)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 10)
            .hairline(.bottom)
            if rows.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let largest = rows.map(\.bytes).max() ?? 1
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, group in
                            GraphRow(group: group, first: index == 0, last: index == rows.count - 1, largest: largest)
                        }
                    }
                    .padding(.top, 2).padding(.bottom, 24)
                }
                .scrollIndicators(.never)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
            PrimaryButton(title: stale.isEmpty ? "Nothing stale here" : "Review \(stale.count) \(stale.count == 1 ? "worktree" : "worktrees")",
                          detail: stale.isEmpty ? nil : Format.bytes(stale.reduce(0) { $0 + $1.reclaimable })) {
                model.openReview(stale.flatMap(\.artifacts))
            }
            .disabled(stale.isEmpty)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
            .hairline(.top)
        }
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
            Text(model.repositories.isEmpty ? "No build output found yet" : model.worktreeFilter == .stale ? "Nothing stale in \(model.selectedRepository ?? "")" : "Nothing to show")
                .font(.sans(13, .medium))
            Text(model.worktreeFilter == .stale ? "Worktrees become stale after \(Format.hours(model.preferences.keepHours)) without builds or open files." : "Kept worktrees appear here with the reason.")
                .font(.sans(11.5)).foregroundStyle(theme.muted).multilineTextAlignment(.center).frame(maxWidth: 240)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var repositoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.repositories, id: \.name) { repository in
                Button {
                    model.repository = repository.name; choosingRepository = false
                } label: {
                    HStack {
                        Image(systemName: "checkmark").opacity(repository.name == model.selectedRepository ? 1 : 0).font(.sans(10, .bold))
                        Text(repository.name).font(.sans(12.5, .medium))
                        Spacer(minLength: 16)
                        Text("\(repository.trees) · \(Format.bytes(repository.bytes))").font(.mono(11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6).frame(minWidth: 220)
    }
}

struct GraphRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let group: WorktreeGroup
    let first: Bool
    let last: Bool
    let largest: Int64

    private var detail: String {
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
                Text(group.name).font(.mono(12, .medium)).foregroundStyle(group.stale ? theme.ink : theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 3) {
                    if !group.stale { Image(systemName: "lock.fill").font(.sans(8)) }
                    Text(detail).lineLimit(1)
                }
                .font(.sans(11)).foregroundStyle(group.stale ? theme.muted : theme.ink.opacity(0.7))
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Format.bytes(group.bytes)).font(.mono(12, .medium)).foregroundStyle(group.stale ? theme.ink : theme.dim).monospacedDigit()
                Capsule().fill(theme.track).frame(width: 50, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(group.stale ? theme.accent : theme.used)
                            .frame(width: max(3, 50 * CGFloat(Double(group.bytes) / Double(max(largest, 1)))), height: 3)
                    }
            }
        }
        .padding(.trailing, 14)
        .contentShape(Rectangle())
        .onTapGesture { if group.stale { model.openReview(group.artifacts) } }
        .help(group.artifacts.flatMap(\.reasons).joined(separator: "\n"))
        .contextMenu {
            if group.stale { Button("Review This Worktree") { model.openReview(group.artifacts) } }
            Button("Reveal in Finder") { model.reveal(group.top) }
            Button(model.preferences.pinned.contains(group.top) ? "Stop Keeping" : "Always Keep") { model.togglePin(group) }
                .disabled(model.demo)
        }
    }

    private var rail: some View {
        Canvas { context, size in
            let x: CGFloat = 12, mid = size.height / 2
            var trunk = Path()
            trunk.move(to: CGPoint(x: x, y: first ? mid : 0))
            trunk.addLine(to: CGPoint(x: x, y: last ? mid : size.height))
            context.stroke(trunk, with: .color(theme.used), lineWidth: 1.5)
            if group.info?.isMain ?? false {
                context.fill(Path(ellipseIn: CGRect(x: x - 4.5, y: mid - 4.5, width: 9, height: 9)), with: .color(theme.ink))
                return
            }
            var branch = Path()
            branch.move(to: CGPoint(x: x, y: 5))
            branch.addCurve(to: CGPoint(x: 24, y: mid), control1: CGPoint(x: x, y: 17), control2: CGPoint(x: 24, y: 13))
            context.stroke(branch, with: .color(group.stale ? theme.accent : theme.used), lineWidth: 1.5)
            let node = CGRect(x: 24 - 3.8, y: mid - 3.8, width: 7.6, height: 7.6)
            if group.stale {
                context.fill(Path(ellipseIn: node), with: .color(theme.dark ? Color(hex: 0x15171B) : Color(hex: 0xF7F7F6)))
                context.stroke(Path(ellipseIn: node), with: .color(theme.accent), lineWidth: 1.6)
            } else {
                context.fill(Path(ellipseIn: node.insetBy(dx: -0.2, dy: -0.2)), with: .color(theme.used))
            }
        }
    }
}
