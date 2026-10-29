import SwiftUI
import AppKit
import HeadroomCore

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Headroom", id: "main") {
            RootView().environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            MenuLabel().environment(model)
        }
    }
}

extension AppModel {
    static let shared = AppModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-icon"), index + 1 < args.count {
            AppIcon.write(to: args[index + 1]); exit(0)
        }
        // A menu bar utility: no Dock icon, the window opens from the menu bar.
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppIcon.image(size: 512)
        if let index = args.firstIndex(of: "--appearance"), index + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[index + 1] == "light" ? .aqua : .darkAqua)
        }
        NSApp.activate()
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let directory = args[index + 1]
            Task { @MainActor in await Snapshots.run(into: directory) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Themed { Screens() }
            .frame(width: 344, height: 592)
    }
}

private struct Screens: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        ZStack {
            Group {
                switch model.screen {
                case .main:
                    Group {
                        switch model.tab {
                        case .disk: DiskView()
                        case .worktrees: WorktreesView()
                        case .history: HistoryView()
                        }
                    }
                    .transition(.opacity)
                case .review: ReviewView().transition(.move(edge: .bottom).combined(with: .opacity))
                case .sweep: SweepView().transition(.opacity)
                case .settings: SettingsView().transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.tab)
            if model.demo && !CommandLine.arguments.contains("--snapshot") {
                Text("DEMO DATA").font(.mono(9, .semibold)).tracking(1).foregroundStyle(theme.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, -21).padding(.trailing, 12)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .onAppear { model.windowOpened() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.windowOpened() }
        .alert("Headroom", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Clean automatically?", isPresented: $model.confirmingSchedule) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On", role: .destructive) { model.setSchedule(true) }
        } message: {
            Text("Every \(Format.hours(model.preferences.intervalHours)), Headroom permanently deletes node_modules and Cargo target folders that have been idle for \(Format.hours(model.preferences.keepHours)), with no review. Folders with open files, running builds, locks, or pins are always kept.")
        }
    }
}

/// The status item exists from launch, so it opens the window once; menu bar apps get no window by default.
struct MenuLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var opened = false
    var body: some View {
        Image(nsImage: MenuIcon.image(pressure: model.pressure, scanned: model.hasScanned))
            .onAppear {
                guard !opened else { return }
                opened = true
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if model.hasScanned {
            Text("\(Format.bytes(model.reclaimable)) reclaimable · \(Format.bytes(model.inventory.available)) free")
        } else {
            Text(model.preferences.roots.isEmpty ? "No folders watched" : model.scanning ? "Scanning…" : "Not scanned yet")
        }
        Button("Open Headroom") { openWindow(id: "main"); NSApp.activate() }.keyboardShortcut("o")
        if model.hasScanned && !(model.eligible.isEmpty && model.recent.isEmpty) {
            Button("Clean Now… \(Format.bytes(model.reclaimable + model.recentBytes))") {
                model.screen = .main; model.cleanNow(); openWindow(id: "main"); NSApp.activate()
            }
            .disabled(model.sweep != nil)
        }
        Button("Scan Now") { Task { await model.scan() } }
            .disabled(model.scanning || model.demo || model.preferences.roots.isEmpty)
        if model.preferences.scheduled {
            Button(model.preferences.paused ? "Resume Automatic Cleanup" : "Pause Automatic Cleanup") { model.togglePaused() }
        }
        Divider()
        Button("Quit Headroom") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Menu bar ring showing how full the disk is. Turns amber under pressure.
enum MenuIcon {
    static func image(pressure: Double, scanned: Bool) -> NSImage {
        let high = scanned && pressure >= 0.9
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY), radius: CGFloat = 6.5
            let track = NSBezierPath(); track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.2
            (high ? NSColor.secondaryLabelColor : NSColor.black.withAlphaComponent(0.3)).setStroke(); track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(scanned ? max(pressure, 0.04) : 0.25), clockwise: true)
            arc.lineWidth = 2.2; arc.lineCapStyle = .round
            (high ? NSColor(red: 0.90, green: 0.64, blue: 0.26, alpha: 1) : NSColor.black).setStroke(); arc.stroke()
            return true
        }
        image.isTemplate = !high
        image.accessibilityDescription = "Headroom"
        return image
    }
}

enum AppIcon {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 1024
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 100 * s, dy: 100 * s), xRadius: 185 * s, yRadius: 185 * s)
            NSGradient(colors: [NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1), NSColor(red: 0.07, green: 0.075, blue: 0.085, alpha: 1)])?.draw(in: tile, angle: -90)
            let center = NSPoint(x: rect.midX, y: rect.midY), radius = 250 * s
            func arc(_ from: CGFloat, _ to: CGFloat, _ color: NSColor) {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius, startAngle: 90 - 360 * from, endAngle: 90 - 360 * to, clockwise: true)
                path.lineWidth = 64 * s; path.lineCapStyle = .round; color.setStroke(); path.stroke()
            }
            arc(0, 1, NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1))
            arc(0, 0.5, NSColor(red: 0.30, green: 0.32, blue: 0.36, alpha: 1))
            arc(0.53, 0.86, NSColor(red: 0.90, green: 0.64, blue: 0.26, alpha: 1))
            let disc = NSBezierPath(ovalIn: NSRect(x: center.x - 150 * s, y: center.y - 150 * s, width: 300 * s, height: 300 * s))
            NSGradient(colors: [NSColor(red: 0.19, green: 0.20, blue: 0.23, alpha: 1), NSColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)])?.draw(in: disc, angle: -90)
            return true
        }
    }
    static func write(to path: String) {
        let size = 1024
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(size: CGFloat(size)).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Demo-mode screenshots of every screen in both appearances, for design review: `Headroom --demo --snapshot <dir>`.
@MainActor
enum Snapshots {
    static func run(into directory: String) async {
        let model = AppModel.shared
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))
        // Real inventories are captured read-only: the sweep steps only run against demo data.
        while !model.demo && (model.scanning || !model.hasScanned) && !model.preferences.roots.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        var full: Inventory?
        for appearance in ["dark", "light"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            let steps: [(String, Double, () -> Void)] = [
                ("1-disk", 0.8, { model.screen = .main; model.tab = .disk }),
                ("1-recent-only", 0.8, { full = model.inventory; model.inventory.artifacts.removeAll(where: \.eligible) }),
                ("2-worktrees", 0.8, { if let full { model.inventory = full }; model.repository = nil; model.worktreeFilter = .all; model.tab = .worktrees }),
                ("2-selected", 0.8, {
                    model.repository = "t3code"
                    model.selected = Set(model.repositoryGroups.filter { $0.waiting || $0.name == "spike/sqlite-wal" }.map(\.top))
                }),
                ("2-review-selected", 0.9, { model.reviewSelection() }),
                ("2-scanning", 0.5, { model.screen = .main; model.selected = []; model.repository = nil; model.scanning = true }),
                ("3-history", 0.8, { model.tab = .history }),
                ("4-review", 0.9, { model.tab = .disk; model.openReview(model.visible); if model.demo { model.toggleExcluded(model.review[2]) } }),
                ("5-sweep", 3.2, { model.startSweep() }),
                ("6-done", 0.8, { model.stopSweep() }),
                ("7-settings", 0.9, { model.sweep = nil; model.screen = .settings }),
            ]
            for (name, wait, apply) in steps where model.demo || !["1-recent-only", "2-selected", "2-review-selected", "2-scanning", "5-sweep", "6-done"].contains(name) {
                apply()
                try? await Task.sleep(for: .seconds(wait))
                capture(to: "\(directory)/\(name)-\(appearance).png")
                if name == "2-scanning" { model.scanning = false }
            }
            model.screen = .main
        }
        exit(0)
    }

    static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("No window to capture: \(NSApp.windows.map { "\($0.frame) visible=\($0.isVisible)" })\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
