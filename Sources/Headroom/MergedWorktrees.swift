import SwiftUI
import HeadroomCore

extension WorktreeRule {
    /// Group title in the Kept list.
    var title: String {
        switch self {
        case .inspectionFailed: "Couldn't check"
        case .mainCheckout: "Main checkouts"
        case .pinned: "Kept by you"
        case .locked: "Locked in Git"
        case .inUse: "In use right now"
        case .nestedWorktree: "Hold another worktree or repository"
        case .uncommitted: "Uncommitted changes"
        case .onlyOnThisMac: "Commits only on this Mac"
        case .openPullRequest: "Open pull requests"
        case .commitsAfterMerge: "Commits after a merge"
        case .notMerged: "Pushed, not merged"
        case .mergeUnknown: "Can't confirm it merged"
        case .recentlyUsed: "Merged, used in the last \(WorktreePolicy.unusedDays) days"
        }
    }
}

extension WorktreeStatus {
    /// Evidence and age, such as `PR #812 merged · unused 9d`.
    var summary: String {
        var parts = [evidence ?? "merged"]
        if let lastUsed { parts.append("unused " + Format.age(lastUsed)) }
        return parts.joined(separator: " · ")
    }
    /// Shortened list of what goes with this worktree and can't be restored.
    func listing(_ names: [String]) -> String {
        names.count > 3 ? names.prefix(3).joined(separator: ", ") + " +\(names.count - 3) more" : names.joined(separator: ", ")
    }
}

/// The Merged filter on the Worktrees tab: what can go, what needs a look, and why everything else stays.
struct MergedWorktreesList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var openRule: WorktreeRule?

    var body: some View {
        let ready = model.readyWorktrees, look = model.lookWorktrees, kept = model.keptWorktrees
        let chosen = model.chosenWorktrees
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.surveying ? "Checking Git and GitHub…" : "Merged work, unused for \(WorktreePolicy.unusedDays)+ days.")
                    .font(.sans(11)).foregroundStyle(theme.muted).lineLimit(1)
                Spacer(minLength: 4)
                Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { model.screen = .worktreeRules } } label: {
                    HStack(spacing: 2) {
                        Text("The rules")
                        Image(systemName: "chevron.right").font(.sans(8.5, .bold))
                    }
                    .font(.sans(11, .medium)).foregroundStyle(theme.accent).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .hairline(.bottom)
            if model.scopedWorktrees.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "tray").font(.sans(22)).foregroundStyle(theme.dim)
                    Text(model.surveying ? "Checking your worktrees" : "No worktrees found yet").font(.sans(13, .medium))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !ready.isEmpty {
                            header("Ready to remove", ready.count)
                            ForEach(ready) { row($0) }
                        }
                        if !look.isEmpty {
                            header("Has other files", look.count, note: "Unchecked so you can look first.")
                            ForEach(look) { row($0) }
                        }
                        if !kept.isEmpty {
                            header("Kept", kept.count, note: "Headroom won't offer these, and here's why.")
                            ForEach(WorktreeRule.allCases.reversed(), id: \.self) { rule in
                                let items = kept.filter { $0.rule == rule }
                                if !items.isEmpty { keptGroup(rule, items) }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.never)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
            PrimaryButton(title: chosen.isEmpty ? "Nothing selected" : "Review \(chosen.count) \(chosen.count == 1 ? "worktree" : "worktrees")",
                          detail: chosen.isEmpty ? nil : Format.bytes(chosen.reduce(0) { $0 + $1.bytes })) {
                model.openWorktreeReview()
            }
            .disabled(chosen.isEmpty)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
            .hairline(.top)
        }
    }

    private func header(_ title: String, _ count: Int, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title).font(.sans(11.5, .semibold)).foregroundStyle(theme.ink)
                Text("\(count)").font(.mono(10.5)).foregroundStyle(theme.dim)
            }
            if let note { Text(note).font(.sans(10.5)).foregroundStyle(theme.muted) }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 5)
    }

    private func row(_ status: WorktreeStatus) -> some View {
        let chosen = model.isChosen(status)
        return Button { withAnimation(.easeOut(duration: 0.12)) { model.toggleChosen(status) } } label: {
            HStack(spacing: 9) {
                Image(systemName: chosen ? "checkmark.square.fill" : "square").font(.sans(14))
                    .foregroundStyle(chosen ? theme.accent : theme.dim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.name).font(.mono(12, .medium)).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.middle)
                    Text(status.summary).font(.sans(11)).foregroundStyle(theme.muted).lineLimit(1)
                    if !status.otherIgnored.isEmpty {
                        Text("has " + status.listing(status.otherIgnored)).font(.sans(11)).foregroundStyle(theme.accent).lineLimit(1).truncationMode(.middle)
                    }
                    if !status.envFiles.isEmpty {
                        Text("includes " + status.listing(status.envFiles)).font(.sans(11)).foregroundStyle(theme.dim).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(Format.bytes(status.bytes)).font(.mono(12, .medium)).monospacedDigit().foregroundStyle(chosen ? theme.ink : theme.dim)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(chosen ? theme.accentSoft : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Format.home(status.top))
        .accessibilityValue(chosen ? "selected" : "not selected")
        .contextMenu { menu(status) }
    }

    private func keptGroup(_ rule: WorktreeRule, _ items: [WorktreeStatus]) -> some View {
        let open = openRule == rule
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { openRule = open ? nil : rule } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.sans(8)).foregroundStyle(theme.dim).frame(width: 14)
                    Text(rule.title).font(.sans(12)).foregroundStyle(theme.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(items.count)").font(.mono(11)).foregroundStyle(theme.muted)
                    Image(systemName: "chevron.right").font(.sans(9, .semibold)).foregroundStyle(theme.dim).rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 14).frame(height: 27).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                ForEach(items) { status in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(status.name).font(.mono(11)).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.middle)
                        Text(status.reason ?? "Kept").font(.sans(10.5)).foregroundStyle(theme.dim).lineLimit(1)
                    }
                    .padding(.leading, 34).padding(.trailing, 14).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .help(Format.home(status.top))
                    .contextMenu { menu(status) }
                }
            }
        }
    }

    @ViewBuilder private func menu(_ status: WorktreeStatus) -> some View {
        Button("Reveal in Finder") { model.reveal(status.top) }
        if status.rule != .mainCheckout {
            Button(model.preferences.pinned.contains(status.top) ? "Stop Keeping" : "Always Keep") { model.toggleKeep(status.top) }
                .disabled(model.demo)
        }
    }
}

/// States every rule in plain words, with how many worktrees each one keeps right now.
struct WorktreeRulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private func count(_ rules: WorktreeRule...) -> Int { model.worktrees.filter { $0.rule.map(rules.contains) ?? false }.count }

    var body: some View {
        VStack(spacing: 0) {
            TopBar {
                IconButton(symbol: "chevron.left", help: "Back") { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { model.screen = .main } }
                    .keyboardShortcut(.cancelAction)
            } title: {
                Text("Worktree rules").font(.sans(13, .semibold)).foregroundStyle(theme.ink)
            } trailing: { Color.clear.frame(width: 24) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Headroom offers to remove a worktree only when all of these are true. It always asks first and never does this automatically.")
                        .font(.sans(12)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                    SectionLabel(text: "The rules").padding(.top, 8)
                    Card {
                        VStack(alignment: .leading, spacing: 9) {
                            rule("Its commits are merged", "In the default branch, main, or staging, or part of a pull request merged into one of them. A matching branch name doesn't count.",
                                 count(.onlyOnThisMac, .openPullRequest, .commitsAfterMerge, .notMerged, .mergeUnknown))
                            rule("Nothing uncommitted", "No changed or untracked files.", count(.uncommitted))
                            rule("Unused for \(WorktreePolicy.unusedDays) days", "No file changes, commits, or checkouts.", count(.recentlyUsed))
                            rule("Nothing has it open", "No terminal, editor, or running process.", count(.inUse))
                            rule("Not protected", "Not the main checkout, not marked Always Keep, and not locked in Git.", count(.mainCheckout, .pinned, .locked))
                            rule("Nothing else inside", "No other worktree or repository in its folders.", count(.nestedWorktree))
                            rule("Headroom could check all of this", "If a check fails, the worktree stays.", count(.inspectionFailed))
                        }
                        .padding(.vertical, 3)
                    }
                    SectionLabel(text: "When one is removed").padding(.top, 10)
                    Card {
                        VStack(alignment: .leading, spacing: 9) {
                            fact("arrow.uturn.backward", "Stays", "The branch and commits. History has a Restore button that recreates the worktree.")
                            fact("trash", "Goes", "The folder, including build output and `.env` files. The review names any `.env` files. They can't be restored.")
                            fact("eye", "You decide", "Other ignored files, like screenshots, can't be restored either. Those worktrees start unchecked.")
                            fact("checkmark.shield", "Checked again", "Every rule runs again just before removal, and Git refuses anything with changes.")
                        }
                        .padding(.vertical, 3)
                    }
                    Text("To read merged pull requests, Headroom uses your GitHub CLI (`gh`) if you have it. Without it, or offline, only branches are checked and the rest stay.")
                        .font(.sans(11)).foregroundStyle(theme.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
    }

    private func rule(_ title: String, _ detail: String, _ kept: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark").font(.sans(10, .bold)).foregroundStyle(theme.accent).frame(width: 12).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.sans(12, .medium))
                    Spacer(minLength: 6)
                    if kept > 0 { Text("keeps \(kept)").font(.mono(10.5)).foregroundStyle(theme.muted) }
                }
                Text(detail).font(.sans(10.5)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fact(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.sans(10.5)).foregroundStyle(theme.muted).frame(width: 12).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.sans(12, .medium))
                Text(.init(detail)).font(.sans(10.5)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct WorktreeReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let list = model.worktreeReview
        let bytes = list.reduce(0) { $0 + $1.bytes }
        let env = list.filter { !$0.envFiles.isEmpty }.count, other = list.filter { !$0.otherIgnored.isEmpty }.count
        VStack(spacing: 0) {
            TopBar {
                IconButton(symbol: "chevron.left", help: "Back") { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { model.screen = .main } }
            } title: {
                Text("Remove worktrees").font(.sans(13, .semibold)).foregroundStyle(theme.ink)
            } trailing: { Color.clear.frame(width: 24) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    BigBytes(bytes: bytes, size: 22)
                    Text("\(list.count) \(list.count == 1 ? "worktree" : "worktrees") · branches stay").font(.mono(11.5)).foregroundStyle(theme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            .hairline(.bottom)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { status in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 8) {
                                Text("\(status.repository)/\(status.name)").font(.mono(11, .medium)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(Format.bytes(status.bytes)).font(.mono(11)).monospacedDigit().foregroundStyle(theme.muted)
                            }
                            Text(status.summary).font(.sans(10.5)).foregroundStyle(theme.muted).lineLimit(1)
                            if !status.envFiles.isEmpty {
                                Text("also deletes " + status.listing(status.envFiles)).font(.sans(10.5)).foregroundStyle(theme.accent).lineLimit(1).truncationMode(.middle)
                            }
                            if !status.otherIgnored.isEmpty {
                                Text("also deletes " + status.listing(status.otherIgnored)).font(.sans(10.5)).foregroundStyle(theme.accent).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .help(Format.home(status.top))
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield").font(.sans(12)).foregroundStyle(theme.accent)
                Text(note(env: env, other: other)).font(.sans(11)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline(.top)
            HStack(spacing: 8) {
                GhostButton(title: "Cancel") { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { model.screen = .main } }
                    .frame(width: 78)
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(title: "Remove \(list.count) \(list.count == 1 ? "worktree" : "worktrees")", detail: Format.bytes(bytes)) { model.startWorktreeRemoval() }
                    .disabled(list.isEmpty)
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
    }

    private func note(env: Int, other: Int) -> String {
        var text = "Restore the source from History. Each worktree is checked again just before removal."
        let lost = [env > 0 ? "`.env` files in \(env)" : nil, other > 0 ? "other ignored files in \(other)" : nil].compactMap { $0 }
        if !lost.isEmpty { text += " Can't be restored: \(lost.joined(separator: " and "))." }
        return text.replacingOccurrences(of: "`", with: "")
    }
}

struct WorktreeRemovalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let state = model.removal ?? WorktreeRemovalState(candidates: [])
        let removed = state.entries.values.filter { $0.outcome == "Cleaned" }.count
        VStack(spacing: 0) {
            TopBar { Color.clear.frame(width: 24) } title: { Brand() } trailing: { Color.clear.frame(width: 24) }
            VStack(spacing: 8) {
                StatusPill(text: state.finished ? (state.failed ? "Removal failed" : state.stopping ? "Stopped" : "Done") : state.stopping ? "Stopping" : "Removing · \(min(state.entries.count + 1, state.candidates.count)) of \(state.candidates.count)",
                           calm: state.finished)
                BigBytes(bytes: state.freed, size: 38).padding(.top, 8)
                Text(state.finished ? "\(removed) removed · \(state.entries.count - removed) kept" : "of \(Format.bytes(state.total)) freed")
                    .font(.mono(12)).foregroundStyle(theme.muted)
            }
            .padding(.top, 22).padding(.bottom, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.candidates) { candidate in
                        let entry = state.entries[candidate.top], current = state.current == candidate.top
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Group {
                                    if let entry { Image(systemName: entry.outcome == "Cleaned" ? "checkmark" : "minus").font(.sans(9.5, .bold)) }
                                    else if current { PulseDot() } else { Color.clear }
                                }
                                .frame(width: 16)
                                Text(Format.compact(candidate.bytes)).frame(width: 44, alignment: .trailing).monospacedDigit()
                                Text(candidate.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 21)
                            if let entry, entry.outcome != "Cleaned" {
                                Text("kept: " + entry.detail).italic().foregroundStyle(theme.dim).lineLimit(2).padding(.leading, 72).padding(.bottom, 3)
                            }
                        }
                        .font(.mono(10.5))
                        .foregroundStyle(entry == nil ? (current ? theme.ink : theme.dim) : entry?.outcome == "Cleaned" ? theme.muted : theme.accent)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 20)
            }
            .scrollIndicators(.never)
            Group {
                if state.finished {
                    PrimaryButton(title: "Done", detail: Format.bytes(state.freed)) { model.closeWorktreeRemoval() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    GhostButton(title: state.stopping ? "Stopping after this worktree…" : "Stop after this worktree") { model.stopWorktreeRemoval() }
                        .disabled(state.stopping)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }
}
