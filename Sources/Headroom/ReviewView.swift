import SwiftUI
import HeadroomCore

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var lines: [Artifact] {
        switch model.reviewFilter {
        case .remove: model.review
        case .kept: model.reviewKept
        case .excluded: model.review.filter { model.excluded.contains($0.path) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar {
                IconButton(symbol: "chevron.left", help: "Back") { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { model.screen = .main } }
            } title: {
                Text("Review plan").font(.sans(13, .semibold)).foregroundStyle(theme.ink)
            } trailing: {
                IconButton(symbol: model.copied ? "checkmark" : "apple.terminal", help: "Copy as headroom-cli command") { model.copyCLI() }
                    .disabled(model.reviewIncluded.isEmpty)
            }
            HStack(spacing: 12) {
                DiskRing(capacity: model.inventory.capacity, available: model.inventory.available, highlight: model.reviewBytes,
                         size: 54, lineWidth: 5, ticks: false) { EmptyView() }
                VStack(alignment: .leading, spacing: 4) {
                    BigBytes(bytes: model.reviewBytes, size: 22)
                    Text(model.excluded.isEmpty ? "\(model.reviewIncluded.count) folders · caches untouched" : "\(model.reviewIncluded.count) folders · \(model.excluded.count) excluded")
                        .font(.mono(11.5)).foregroundStyle(theme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            sheet
        }
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            Capsule().fill(theme.line).frame(width: 34, height: 4).padding(.top, 7)
            HStack(spacing: 6) {
                chip(.remove, model.reviewIncluded.count)
                chip(.kept, model.reviewKept.count)
                chip(.excluded, model.excluded.count)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let grouped = Dictionary(grouping: lines) { $0.worktree?.top ?? $0.project }
                    let order = lines.map { $0.worktree?.top ?? $0.project }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    ForEach(order, id: \.self) { top in
                        let items = grouped[top] ?? []
                        header(items[0])
                        ForEach(items) { line($0) }
                    }
                    if lines.isEmpty {
                        Text(model.reviewFilter == .kept ? "Nothing kept in this selection." : model.reviewFilter == .excluded ? "Click a line to exclude it." : "Everything is excluded.")
                            .font(.sans(11.5)).foregroundStyle(theme.dim).frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield").font(.sans(12)).foregroundStyle(theme.accent)
                Text("Each folder is checked again for open files and running builds just before it is deleted. Deletion is permanent.")
                    .font(.sans(11)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline(.top)
            HStack(spacing: 8) {
                GhostButton(title: "Cancel") { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { model.screen = .main } }
                    .frame(width: 78)
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(title: "Delete \(model.reviewIncluded.count) \(model.reviewIncluded.count == 1 ? "folder" : "folders")",
                              detail: Format.bytes(model.reviewBytes)) { model.startSweep() }
                    .disabled(model.reviewIncluded.isEmpty)
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .background(theme.sheet, in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14).strokeBorder(theme.line, lineWidth: 1)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
        }
        .shadow(color: .black.opacity(theme.dark ? 0.35 : 0.08), radius: 12, y: -6)
    }

    private func chip(_ filter: ReviewFilter, _ count: Int) -> some View {
        let on = model.reviewFilter == filter
        return Button { model.reviewFilter = filter } label: {
            HStack(spacing: 5) {
                Text(filter.rawValue)
                Text("\(count)").font(.mono(11)).opacity(0.8)
            }
            .font(.sans(11, .medium))
            .padding(.horizontal, 9).frame(height: 24)
            .foregroundStyle(on ? theme.accent : theme.muted)
            .background(on ? theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? .clear : theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func header(_ artifact: Artifact) -> some View {
        let info = artifact.worktree
        let name = info.map { "\($0.repository)/\($0.branch ?? URL(fileURLWithPath: $0.top).lastPathComponent)" } ?? artifact.name
        var meta = "idle " + Format.age(artifact.latestWrite)
        if let changed = info?.changedFiles { meta += changed == 0 ? " · clean" : " · \(changed) changed" }
        return HStack(spacing: 0) {
            Text("#").frame(width: 14, alignment: .leading)
            Text(name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Text("  " + meta).foregroundStyle(theme.dim).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.mono(10.5)).foregroundStyle(theme.muted)
        .padding(.horizontal, 14).padding(.top, 7).frame(height: 24, alignment: .bottom)
    }

    @ViewBuilder private func line(_ artifact: Artifact) -> some View {
        if model.reviewFilter == .kept {
            VStack(alignment: .leading, spacing: 0) {
                row(sign: "=", artifact.relativePath, artifact.bytes, color: theme.muted)
                HStack(spacing: 0) {
                    Color.clear.frame(width: 14)
                    Text("kept: " + Reason.short(Reason.primary(artifact.reasons) ?? "")).italic().lineLimit(1)
                }
                .font(.mono(10.5)).foregroundStyle(theme.dim).padding(.horizontal, 14).frame(height: 17)
            }
            .help(artifact.reasons.joined(separator: "\n"))
        } else {
            let excluded = model.excluded.contains(artifact.path)
            Button { withAnimation(.easeOut(duration: 0.15)) { model.toggleExcluded(artifact) } } label: {
                row(sign: "-", excluded ? artifact.relativePath + " excluded" : artifact.relativePath, artifact.bytes,
                    color: excluded ? theme.dim : theme.ink, strike: excluded)
                    .background(excluded ? .clear : theme.accentSoft)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(excluded ? "Include \(Format.home(artifact.path))" : "Exclude \(Format.home(artifact.path))")
        }
    }

    private func row(sign: String, _ text: String, _ bytes: Int64, color: Color, strike: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(sign).fontWeight(.semibold).foregroundStyle(sign == "-" && !strike ? theme.accent : color).frame(width: 14, alignment: .leading)
            Text(text).lineLimit(1).truncationMode(.middle).strikethrough(strike, color: theme.dim)
            Spacer(minLength: 8)
            Text(Format.bytes(bytes)).strikethrough(strike, color: theme.dim).monospacedDigit()
        }
        .font(.mono(10.5)).foregroundStyle(color)
        .padding(.horizontal, 14).frame(height: 17)
    }
}
