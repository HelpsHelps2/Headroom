import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = Self.icon()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private static func icon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { _ in
            func oval(_ rect: NSRect, _ color: NSColor) { color.setFill(); NSBezierPath(ovalIn: rect).fill() }
            NSColor(calibratedRed: 0.79, green: 0.85, blue: 0.68, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 488, height: 488), xRadius: 112, yRadius: 112).fill()
            let fur = NSColor(calibratedRed: 0.98, green: 0.86, blue: 0.66, alpha: 1)
            let pink = NSColor(calibratedRed: 0.91, green: 0.61, blue: 0.43, alpha: 1)
            oval(NSRect(x: 151, y: 248, width: 64, height: 184), fur)
            oval(NSRect(x: 278, y: 264, width: 64, height: 184), fur)
            oval(NSRect(x: 169, y: 280, width: 27, height: 120), pink)
            oval(NSRect(x: 296, y: 296, width: 27, height: 120), pink)
            oval(NSRect(x: 99, y: 95, width: 314, height: 260), fur)
            oval(NSRect(x: 172, y: 228, width: 18, height: 20), .darkGray)
            oval(NSRect(x: 322, y: 228, width: 18, height: 20), .darkGray)
            oval(NSRect(x: 242, y: 183, width: 28, height: 19), .brown)
            oval(NSRect(x: 131, y: 182, width: 54, height: 30), pink.withAlphaComponent(0.6))
            oval(NSRect(x: 327, y: 182, width: 54, height: 30), pink.withAlphaComponent(0.6))
            return true
        }
    }
}

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Burrow") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1040, minHeight: 720)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add development folder…") { model.addFolder() }.keyboardShortcut("o")
                Button("Scan folders") { Task { await model.scan() } }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings = true }.keyboardShortcut(",")
            }
        }
        MenuBarExtra("Burrow", systemImage: "leaf.fill") {
            Text(model.busy ? "Looking around the burrow…" : "\(model.inventory.artifacts.count) build directories")
            if model.demo { Text("Demo data — cleanup disabled") }
            Button("Open Burrow") { NSApplication.shared.activate(ignoringOtherApps: true); NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil) }
            Button("Scan now") { Task { await model.scan() } }.disabled(model.busy || model.demo)
            Button(model.preferences.paused ? "Resume automatic cleanup" : "Pause automatic cleanup") { model.togglePaused() }.disabled(model.demo)
            Divider()
            Button("Quit Burrow") { NSApplication.shared.terminate(nil) }
        }
    }
}
