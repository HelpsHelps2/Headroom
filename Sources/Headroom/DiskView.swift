import SwiftUI
import HeadroomCore

struct DiskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TopBar {
                ScanButton()
            } title: { Brand() } trailing: {
                IconButton(symbol: "gearshape", help: "Settings") { model.screen = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            Tabs(selection: $model.tab)
            VStack(spacing: 5) {
                StatusPill(text: model.statusText, calm: model.calm)
                Text(freeLine).font(.mono(12.5)).foregroundStyle(theme.muted).monospacedDigit()
            }
            .padding(.top, firstLaunch ? 16 : 24)
            DiskRing(capacity: model.inventory.capacity, available: model.inventory.available, highlight: onlyRecent ? model.recentBytes : model.reclaimable, size: firstLaunch ? 212 : 250) {
                Button(action: coreAction) { CoreDisc(size: firstLaunch ? 132 : 156) { core } }
                    .buttonStyle(PressStyle())
                    .disabled(model.hasScanned && model.eligible.isEmpty && model.recent.isEmpty && !model.preferences.roots.isEmpty)
                    .accessibilityLabel(model.preferences.roots.isEmpty ? (model.chosenSuggestions.isEmpty ? "Add folder" : "Watch \(model.chosenSuggestions.count) folders")
                                        : onlyRecent ? "Clean \(Format.bytes(model.recentBytes)) now" : "Reclaim \(Format.bytes(model.reclaimable))")
            }
            .padding(.top, firstLaunch ? 8 : 14)
            if firstLaunch {
                suggestionList.padding(.horizontal, 14).padding(.top, 12)
                Spacer(minLength: 0)
            } else {
                planRow.padding(.horizontal, 14).padding(.top, 22)
                if !model.eligible.isEmpty && !model.recent.isEmpty { cleanEverything.padding(.horizontal, 14).padding(.top, 6) }
                scopeRow.padding(.horizontal, 14).padding(.top, 8)
                Spacer(minLength: 0)
                footer
            }
        }
    }

    private var firstLaunch: Bool { model.preferences.roots.isEmpty }
    /// Nothing is stale, but recent builds could go now.
    private var onlyRecent: Bool { model.hasScanned && model.eligible.isEmpty && !model.recent.isEmpty }

    private var cleanEverything: some View {
        Button { model.cleanNow() } label: {
            HStack(spacing: 4) {
                Text("Clean now, including \(Format.bytes(model.recentBytes)) built recently")
                Image(systemName: "chevron.right").font(.sans(8.5, .bold))
            }
            .font(.sans(11.5, .medium)).foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2).frame(height: 22).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Review stale folders together with folders built in the last \(Format.hours(model.preferences.keepHours))")
    }

    private var freeLine: String {
        if model.preferences.roots.isEmpty {
            guard model.inventory.capacity > 0 else { return "Watches worktrees for stale builds" }
            return "\(Format.bytes(model.inventory.available)) free on \(model.inventory.volume.isEmpty ? "this disk" : model.inventory.volume)"
        }
        guard model.hasScanned else { return "Looking through your worktrees" }
        let volume = model.inventory.volume.isEmpty ? "this disk" : model.inventory.volume
        return "\(Format.bytes(model.inventory.available)) free on \(volume)"
    }

    private func coreAction() {
        if model.preferences.roots.isEmpty {
            if model.chosenSuggestions.isEmpty { model.addFolder() } else { model.watchChosenSuggestions() }
        }
        else if !model.eligible.isEmpty { model.openReview(model.visible) }
        else if !model.recent.isEmpty { model.cleanNow() }
    }

    @ViewBuilder private var core: some View {
        if model.preferences.roots.isEmpty {
            let count = model.chosenSuggestions.count
            VStack(spacing: count > 0 ? 4 : 8) {
                Image(systemName: count > 0 ? "eye" : "folder.badge.plus").font(.sans(count > 0 ? 17 : 22, .regular)).foregroundStyle(theme.ink.opacity(0.7))
                if count > 0 {
                    Text("Watch \(count)").font(.mono(21, .medium)).tracking(-0.6)
                    Text(count == 1 ? "FOLDER" : "FOLDERS").font(.mono(10, .semibold)).tracking(1.4).foregroundStyle(theme.accent).padding(.top, 3)
                } else {
                    Text("ADD FOLDER").font(.mono(10, .semibold)).tracking(1.4).foregroundStyle(theme.accent)
                }
            }
        } else if !model.hasScanned {
            VStack(spacing: 8) {
                Spinner()
                Text(model.scanProgress.total > 0 ? "\(model.scanProgress.done) of \(model.scanProgress.total)" : "finding folders")
                    .font(.mono(11)).foregroundStyle(theme.muted).monospacedDigit()
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "arrow.down.to.line").font(.sans(17, .regular)).foregroundStyle(theme.ink.opacity(0.7))
                BigBytes(bytes: onlyRecent ? model.recentBytes : model.reclaimable)
                Text(onlyRecent ? "CLEAN NOW" : model.eligible.isEmpty ? "NOTHING STALE" : "RECLAIM").font(.mono(10, .semibold)).tracking(1.4)
                    .foregroundStyle(model.eligible.isEmpty && !onlyRecent ? theme.dim : theme.accent).padding(.top, 3)
            }
        }
    }

    private var planRow: some View {
        let repos = Set(model.eligible.map { $0.worktree?.repository ?? $0.project }).count
        let (title, detail, link): (String, String, String?) = {
            if model.preferences.roots.isEmpty { return ("Nothing is deleted unreviewed", "Finds node_modules and Cargo target folders", nil) }
            if !model.hasScanned { return ("Inspecting build output", "Checking processes, locks, and Git state", nil) }
            if onlyRecent {
                let trees = model.groups.filter(\.waiting).count
                return ("\(trees) \(trees == 1 ? "worktree" : "worktrees") built recently", "Skips the \(Format.hours(model.preferences.keepHours)) wait", "Clean now")
            }
            if model.eligible.isEmpty {
                return ("Nothing idle long enough", "\(model.kept.count) folders kept · \(Format.hours(model.preferences.keepHours)) grace period", model.kept.isEmpty ? nil : "Why")
            }
            let folders = model.eligible.count == 1 ? "1 folder" : "\(model.eligible.count) folders"
            return ("\(folders) · \(repos) \(repos == 1 ? "repo" : "repos")", "\(model.kept.count) kept active · caches untouched", "Review")
        }()
        return Button {
            if !model.eligible.isEmpty { model.openReview(model.visible) }
            else if onlyRecent { model.cleanNow() }
            else if !model.kept.isEmpty { model.worktreeFilter = .kept; model.tab = .worktrees }
        } label: {
            Card {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.mono(12, .medium)).foregroundStyle(theme.ink)
                        Text(detail).font(.sans(11.5)).foregroundStyle(theme.muted)
                    }
                    Spacer(minLength: 0)
                    if let link {
                        HStack(spacing: 3) { Text(link); Image(systemName: "chevron.right").font(.sans(9, .bold)) }
                            .font(.sans(11.5, .semibold)).foregroundStyle(theme.accent)
                    }
                }
                .lineLimit(1)
            }
        }
        .buttonStyle(PressStyle())
        .disabled(link == nil)
    }

    /// First launch: folders found on this Mac, pre-checked, so the first press starts watching them.
    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: model.findingSuggestions ? "Looking for your code" : model.suggestions.isEmpty ? "Choose a folder" : "Found on this Mac")
            Card {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.suggestions) { suggestion in
                                let on = model.chosenSuggestions.contains(suggestion.path)
                                Button { withAnimation(.easeOut(duration: 0.15)) { model.toggleSuggestion(suggestion) } } label: {
                                    HStack(spacing: 10) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(on ? theme.accent : .clear)
                                            .strokeBorder(on ? .clear : theme.dim, lineWidth: 1.2)
                                            .frame(width: 14, height: 14)
                                            .overlay { if on { Image(systemName: "checkmark").font(.sans(8.5, .heavy)).foregroundStyle(theme.accentInk) } }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(Format.home(suggestion.path)).font(.mono(12, .medium)).foregroundStyle(on ? theme.ink : theme.muted)
                                                .lineLimit(1).truncationMode(.middle)
                                            Text(suggestion.detail).font(.sans(11)).foregroundStyle(theme.muted).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(height: 34).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? [.isSelected] : [])
                                .hairline(.bottom)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 34 * 4)
                    .fixedSize(horizontal: false, vertical: true)
                    Button { model.addFolder() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.sans(10, .bold))
                            Text(model.suggestions.isEmpty ? "Choose a folder with your repositories…" : "Choose another folder…")
                            Spacer()
                        }
                        .font(.sans(12, .medium)).foregroundStyle(theme.accent).frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
            }
            Text("Watching only scans. Nothing is deleted until you review it.")
                .font(.sans(11)).foregroundStyle(theme.dim).padding(.horizontal, 2)
        }
    }

    private var scopeRow: some View {
        Button { model.screen = .settings } label: {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "folder").font(.sans(12)).foregroundStyle(theme.muted)
                        .frame(width: 26, height: 26).background(theme.segment, in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scopeTitle)
                            .font(.mono(12, .medium)).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.middle)
                        Text(model.hasScanned ? "\(model.groups.count) worktrees with build output" : "Choose where your repositories live")
                            .font(.sans(11)).foregroundStyle(theme.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.sans(10, .semibold)).foregroundStyle(theme.dim)
                }
            }
        }
        .buttonStyle(PressStyle())
    }

    private var scopeTitle: String {
        guard let first = model.preferences.roots.first else { return "No folders yet" }
        let more = model.preferences.roots.count - 1
        return Format.home(first.path) + (more > 0 ? " +\(more)" : "")
    }

    private var footer: some View {
        // New folders are review-only; automatic cleanup counts only for folders explicitly opted in.
        let on = model.preferences.scheduled && !model.preferences.paused && model.preferences.roots.contains(where: \.automatic)
        return HStack(spacing: 8) {
            Group {
                if !model.preferences.scheduled || !model.preferences.roots.contains(where: \.automatic) { Text("Automatic cleanup off") }
                else if model.preferences.paused { Text("Automatic cleanup paused") }
                else { Text("Automatic cleanup every ") + Text(Format.hours(model.preferences.intervalHours)).font(.mono(11.5, .medium)).foregroundColor(theme.ink) }
            }
            .font(.sans(11.5)).foregroundStyle(theme.muted)
            Spacer()
            Switch(isOn: on, label: "Automatic cleanup") {
                if model.preferences.paused { model.togglePaused() } else { model.requestSchedule(!on) }
            }
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 13)
        .hairline(.top)
    }
}

struct Spinner: View {
    @Environment(\.theme) private var theme
    @State private var spinning = false
    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true } }
    }
}
