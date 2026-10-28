import SwiftUI
import HeadroomCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TopBar {
                IconButton(symbol: "chevron.left", help: "Back") { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { model.screen = .main } }
                    .keyboardShortcut(.cancelAction)
            } title: {
                Text("Settings").font(.sans(13, .semibold)).foregroundStyle(theme.ink)
            } trailing: { Color.clear.frame(width: 24) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Watched folders")
                    Card {
                        VStack(spacing: 0) {
                            ForEach(model.preferences.roots) { root in
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").font(.sans(11)).foregroundStyle(theme.muted)
                                    Text(Format.home(root.path)).font(.mono(11.5)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    if model.preferences.scheduled {
                                        Text("auto").font(.mono(10)).foregroundStyle(theme.dim)
                                        Switch(isOn: root.automatic, label: "Automatic cleanup in \(root.path)") { model.toggleAutomatic(root) }
                                    }
                                    IconButton(symbol: "xmark", help: "Stop watching") { model.removeRoot(root) }.disabled(model.demo)
                                }
                                .frame(height: 30)
                                .hairline(.bottom)
                            }
                            Button { model.addFolder() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus").font(.sans(10, .bold))
                                    Text("Add folder…")
                                    Spacer()
                                }
                                .font(.sans(12, .medium)).foregroundStyle(theme.accent).frame(height: 30).contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                            .disabled(model.demo)
                        }
                    }
                    SectionLabel(text: "Automatic cleanup").padding(.top, 10)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            setting("Clean automatically", detail: "Deletes eligible output without a review") {
                                Switch(isOn: model.preferences.scheduled, label: "Clean automatically") { model.requestSchedule(!model.preferences.scheduled) }
                            }
                            choices("Run every", [6, 12, 24, 48], selected: model.preferences.intervalHours) { model.setInterval($0) }
                                .disabled(!model.preferences.scheduled).opacity(model.preferences.scheduled ? 1 : 0.5)
                            choices("Idle at least", [6, 12, 24, 72], selected: model.preferences.keepHours) { model.setKeepHours($0) }
                            setting("Pause", detail: "Keeps watching, stops deleting") {
                                Switch(isOn: model.preferences.paused, label: "Pause automatic cleanup") { model.togglePaused() }
                            }
                            .disabled(!model.preferences.scheduled).opacity(model.preferences.scheduled ? 1 : 0.5)
                        }
                        .padding(.vertical, 3)
                    }
                    SectionLabel(text: "General").padding(.top, 10)
                    Card {
                        setting("Open at login", detail: "Lives in the menu bar") {
                            Switch(isOn: model.opensAtLogin, label: "Open at login") { model.toggleLogin() }
                        }
                        .padding(.vertical, 3)
                    }
                    SectionLabel(text: "Never touched").padding(.top, 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Source, branches, lockfiles, and whole worktrees. Shared caches:")
                            .font(.sans(11)).foregroundStyle(theme.muted).padding(.bottom, 2)
                        ForEach(model.inventory.protectedCaches.isEmpty ? defaultCaches : model.inventory.protectedCaches, id: \.self) {
                            Text(Format.home($0)).font(.mono(10.5)).foregroundStyle(theme.dim)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
    }

    private var defaultCaches: [String] { ["~/.cargo", "~/.npm", "~/.bun", "~/Library/pnpm", "~/Library/Caches/Yarn", "sccache"] }

    private func setting<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.sans(12, .medium))
                Text(detail).font(.sans(10.5)).foregroundStyle(theme.muted)
            }
            Spacer()
            control()
        }
    }

    private func choices(_ title: String, _ hours: [Double], selected: Double, action: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.sans(12, .medium))
            Spacer()
            HStack(spacing: 0) {
                ForEach(hours, id: \.self) { value in
                    Button { action(value) } label: {
                        Text(Format.hours(value)).font(.mono(10.5, .medium))
                            .foregroundStyle(selected == value ? theme.ink : theme.muted)
                            .frame(width: 38, height: 20)
                            .background(selected == value ? theme.segmentOn : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(theme.segment, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
