import SwiftUI
import BurrowCore
import ServiceManagement

enum Palette {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.92)
    static let ink = Color(red: 0.20, green: 0.27, blue: 0.23)
    static let muted = Color(red: 0.43, green: 0.47, blue: 0.41)
    static let green = Color(red: 0.28, green: 0.40, blue: 0.27)
    static let line = Color(red: 0.86, green: 0.87, blue: 0.81)
    static let peach = Color(red: 0.91, green: 0.61, blue: 0.43)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider().overlay(Palette.line)
            VStack(spacing: 0) {
                header
                if model.page == "History" { history }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            hero
                            metrics
                            if !model.inventory.issues.isEmpty {
                                Label("\(model.inventory.issues.count) inspection notes — some folders may need attention", systemImage: "info.circle")
                                    .font(.callout).foregroundStyle(Palette.muted)
                                    .help(model.inventory.issues.joined(separator: "\n"))
                            }
                            projectBrowser
                        }.padding(30)
                    }
                }
                footer
            }.background(Palette.paper)
        }
        .foregroundStyle(Palette.ink)
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        .sheet(item: Binding(get: { model.plan.map(PlanSheet.init) }, set: { if $0 == nil { model.plan = nil } })) { item in
            ReviewView(plan: item.plan).environmentObject(model)
        }
        .alert("Burrow needs a moment", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "leaf.fill").font(.title2).rotationEffect(.degrees(-25))
                Text("burrow").font(.system(size: 27, weight: .bold, design: .rounded))
            }.padding(.top, 36).padding(.bottom, 36)
            Text("YOUR LITTLE WORKSHOP").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Palette.muted)
            nav("Projects", symbol: "square.grid.2x2")
            nav("History", symbol: "clock.arrow.circlepath")
            Button { model.showSettings = true } label: {
                Label("Settings", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.buttonStyle(.plain)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").font(.title2).foregroundStyle(Palette.green)
                Text("The good stuff stays.").font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Your source and shared compiler caches are protected.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(16).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            Text("MADE FOR YOUR MAC").font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(Palette.muted).padding(.top, 12)
        }.padding(18).background(Color(red: 0.92, green: 0.93, blue: 0.87))
    }
    private func nav(_ name: String, symbol: String) -> some View {
        Button { model.page = name } label: {
            Label(name, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(model.page == name ? Palette.green.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).fontWeight(model.page == name ? .semibold : .regular)
    }
    private var header: some View {
        HStack {
            Text(model.page).font(.system(size: 17, weight: .semibold, design: .rounded))
            if model.demo { Text("DEMO").font(.system(size: 9, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 4).background(Palette.peach.opacity(0.25), in: Capsule()) }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button { model.addFolder() } label: { Label("Add folder", systemImage: "folder.badge.plus") }.disabled(model.demo || model.busy)
            Button { Task { await model.scan() } } label: { Label("Scan folders", systemImage: "arrow.clockwise") }.disabled(model.demo || model.busy || model.preferences.roots.isEmpty)
        }.buttonStyle(.bordered).padding(.horizontal, 30).padding(.vertical, 18)
    }
    private var hero: some View {
        ZStack(alignment: .leading) {
            WoodlandScene(pressure: model.pressure).frame(height: 228).clipShape(RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 12) {
                Text("A LITTLE SPACE TO BREATHE").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Palette.green)
                Text(model.inventory.artifacts.isEmpty ? "Good work needs\na little room." : model.mood)
                    .font(.system(size: 32, weight: .semibold, design: .serif)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 350, alignment: .leading)
                Text(model.preferences.roots.isEmpty ? "Add your development folders.\nWe'll find the leftovers worth letting go." : "Tidy old builds. Keep your momentum.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
                if model.preferences.roots.isEmpty {
                    Button("Find my build output", systemImage: "folder.badge.plus") { model.addFolder() }.buttonStyle(.borderedProminent).tint(Palette.green)
                } else {
                    HStack(spacing: 6) { Circle().fill(Palette.green).frame(width: 6, height: 6); Text("Shared compiler caches stay protected").font(.system(size: 11, weight: .medium)) }
                }
            }.padding(28)
        }
    }
    private var metrics: some View {
        HStack(spacing: 0) {
            metric("READY FOR REVIEW", value: Paths.bytes(model.reclaimable), note: "private, inactive build output", symbol: "sparkles")
            Divider().frame(height: 58)
            metric("BUILD DIRECTORIES", value: "\(model.inventory.artifacts.count)", note: "across your watched folders", symbol: "shippingbox")
            Divider().frame(height: 58)
            metric("AVAILABLE ON DISK", value: model.inventory.capacity > 0 ? Paths.bytes(model.inventory.available) : "—", note: "estimates can differ on APFS", symbol: "internaldrive")
        }.padding(.vertical, 20).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
    }
    private func metric(_ title: String, value: String, note: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
            Text(note).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
    }
    private var projectBrowser: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("A look around").font(.system(size: 20, weight: .semibold, design: .serif))
                Spacer()
                Picker("Show", selection: $model.filter) { ForEach(["All projects", "Ready to clean", "Protected"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 145)
                HStack { Image(systemName: "magnifyingglass"); TextField("Find a project or reason", text: $model.query).textFieldStyle(.plain) }.foregroundStyle(Palette.muted).padding(9).background(.white, in: RoundedRectangle(cornerRadius: 8)).frame(width: 220)
            }
            if model.artifacts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.preferences.roots.isEmpty ? "folder.badge.plus" : "leaf").font(.system(size: 32)).foregroundStyle(Palette.green)
                    Text(model.preferences.roots.isEmpty ? "Your workshop starts here." : "Nothing matches this view.").font(.system(size: 18, weight: .medium, design: .rounded))
                    Text(model.preferences.roots.isEmpty ? "Choose a folder containing your repositories or worktrees." : "Burrow currently recognizes standard private Cargo target directories.")
                        .font(.callout).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity).padding(42).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 0) {
                        ForEach(model.artifacts) { artifact in
                            Button { model.selection = artifact.path } label: { projectRow(artifact) }.buttonStyle(.plain)
                            if artifact.id != model.artifacts.last?.id { Divider().padding(.leading, 52) }
                        }
                    }.background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    if let selected = model.selected { inspector(selected).frame(width: 252) }
                }
                HStack {
                    Text("Estimated allocated size · source files stay put").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Review eligible output", systemImage: "sparkles") {
                        Task { await model.review(Set(model.inventory.artifacts.filter(\.eligible).map(\.path))) }
                    }.buttonStyle(.borderedProminent).tint(Palette.green).disabled(model.reclaimable == 0 || model.busy || model.demo)
                }
            }
        }
    }
    private func projectRow(_ artifact: Artifact) -> some View {
        HStack(spacing: 12) {
            Image(systemName: artifact.eligible ? "shippingbox" : "shield.lefthalf.filled").font(.system(size: 17)).foregroundStyle(artifact.eligible ? Palette.green : Palette.muted).frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(artifact.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(artifact.eligible ? "Ready for review" : (artifact.reasons.first ?? "Protected")).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Paths.bytes(artifact.bytes)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.padding(15).background(model.selection == artifact.path ? Palette.green.opacity(0.08) : .clear)
    }
    private func inspector(_ artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("THE DETAILS").font(.system(size: 9, weight: .bold)).tracking(1.3); Spacer(); Image(systemName: "info.circle") }.foregroundStyle(Palette.muted)
            Text(artifact.name).font(.system(size: 17, weight: .semibold, design: .rounded)).textSelection(.enabled)
            Text(artifact.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Divider()
            Label(artifact.eligible ? "Private Cargo output" : "Staying right here", systemImage: artifact.eligible ? "checkmark.circle" : "shield.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.green)
            if artifact.eligible {
                Text("No activity observed. Source and shared caches are excluded. Rebuilding this output may be needed later.").font(.system(size: 11)).lineSpacing(4)
                Text(Date().timeIntervalSince(artifact.firstObserved) < model.preferences.keepHours * 3600 ? "Manual review available. Automatic cleanup is still observing this directory." : "Observation window complete.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            } else {
                ForEach(artifact.reasons, id: \.self) { Text($0).font(.system(size: 11)).lineSpacing(3) }
            }
            Text("Last write: \(artifact.latestWrite.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(Palette.muted)
            Button(model.preferences.pinned.contains(artifact.project) ? "Unpin project" : "Keep this project", systemImage: "pin") { model.pin(artifact) }.disabled(model.demo || model.busy)
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.selectFile(artifact.path, inFileViewerRootedAtPath: artifact.project) }.disabled(model.demo)
            if artifact.eligible {
                Button("Review this output") { Task { await model.review([artifact.path]) } }.disabled(model.demo || model.busy)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(red: 0.92, green: 0.93, blue: 0.87), in: RoundedRectangle(cornerRadius: 14))
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: model.preferences.paused ? "pause.circle" : "leaf")
            Text(model.preferences.paused ? "Automatic cleanup paused" : model.preferences.scheduled ? "Scheduled cleanup enabled · keep Burrow running" : "Automatic cleanup is off")
            Spacer()
            if model.inventory.scannedAt != .distantPast { Text("Last look \(model.inventory.scannedAt.formatted(date: .omitted, time: .shortened))") }
        }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 30).padding(.vertical, 13).background(.white.opacity(0.5))
    }
    private var history: some View {
        List {
            if model.history.isEmpty { Text("A quiet history. Cleanup results will appear here.").foregroundStyle(Palette.muted) }
            ForEach(model.history) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(item.outcome).fontWeight(.semibold); Spacer(); Text(item.date.formatted()).foregroundStyle(Palette.muted) }
                    Text(item.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(item.detail).font(.callout)
                    if item.bytes > 0 { Text("\(Paths.bytes(item.bytes)) of output removed (estimated)").font(.caption) }
                }.padding(.vertical, 8)
            }
        }.scrollContentBackground(.hidden)
    }
}

private struct PlanSheet: Identifiable { let plan: CleanupPlan; var id: UUID { plan.id }; init(_ plan: CleanupPlan) { self.plan = plan } }

struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    let plan: CleanupPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("A little room, carefully made.", systemImage: "sparkles").font(.system(size: 25, weight: .semibold, design: .serif))
            Text("Permanently delete \(Paths.bytes(plan.bytes)) of generated output from \(plan.candidates.count) build directories?")
            Text("Shared compiler caches and source files are preserved. Deleted build output cannot be undone; Cargo will rebuild what it needs. Activity checks are best effort and cannot exclude every concurrent build.").font(.callout).foregroundStyle(Palette.muted)
            ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(plan.candidates) { Text($0.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } } }.frame(maxHeight: 180)
            HStack { Button("Cancel") { model.plan = nil }.keyboardShortcut(.cancelAction); Spacer(); Button("Delete build output", role: .destructive) { Task { await model.clean() } }.buttonStyle(.borderedProminent).tint(Palette.green) }
        }.padding(30).frame(width: 560).background(Palette.paper)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var consent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Make yourself at home.").font(.system(size: 27, weight: .semibold, design: .serif))
            Form {
                Section("Watched folders") {
                    ForEach(model.preferences.roots.indices, id: \.self) { index in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(model.preferences.roots[index].path).font(.system(.caption, design: .monospaced)).lineLimit(2)
                                Spacer()
                                Button("Remove", systemImage: "minus.circle") { model.preferences.roots.remove(at: index) }.labelStyle(.iconOnly)
                            }
                            Toggle("Allow scheduled cleanup in this folder", isOn: $model.preferences.roots[index].automatic)
                        }.padding(.vertical, 4)
                    }
                    Button("Add folder…") { model.addFolder() }
                }
                Section("Inactivity & schedule") {
                    TextField("Keep output for at least (hours)", value: $model.preferences.keepHours, format: .number)
                    TextField("Run cleanup every (hours)", value: $model.preferences.intervalHours, format: .number)
                    Toggle("Enable scheduled cleanup", isOn: $model.preferences.scheduled).disabled(!consent && !model.preferences.scheduled)
                    Toggle("I understand scheduled cleanup permanently deletes eligible generated output. Rebuilding is the recovery path.", isOn: $consent).font(.caption)
                    Toggle("Pause automatic cleanup", isOn: $model.preferences.paused)
                    Toggle("Open Burrow at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { model.enableLogin($0) }))
                    Text("Burrow observes every five minutes while running, including with its window closed. It preserves shared caches and uncertain or active projects. Quit stops background work; reopening starts a fresh observation window after a gap.").font(.caption).foregroundStyle(Palette.muted)
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Done") { Task { await model.persist(); dismiss(); await model.scan() } }.buttonStyle(.borderedProminent).tint(Palette.green) }
        }.padding(24).frame(width: 640, height: 640).background(Palette.paper)
        .onAppear { consent = model.preferences.scheduled }
    }
}
