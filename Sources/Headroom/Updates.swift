import AppKit
import Observation
import Sparkle

/// Software updates through Sparkle. Headroom checks the signed appcast on GitHub Releases once a day, downloads new
/// versions in the background, and installs them when it is idle (no sweep or scan running and not in front), or on quit.
/// Every update must carry an EdDSA signature from the release key and the same Developer ID signature as this app.
@MainActor @Observable
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    /// False in demo mode and in builds without an update key, such as `swift run`.
    private(set) var enabled = false
    private(set) var canCheck = false
    private(set) var installsAutomatically = false
    /// A newer version a scheduled check found while automatic installs are off.
    private(set) var available: String?
    /// A downloaded version that installs on the next restart.
    private(set) var ready: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        do { try controller.updater.start() } catch {
            NSLog("Headroom updates are off: %@", error.localizedDescription)
            return
        }
        enabled = true
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
        ]
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.installIfIdle() }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    func setInstallsAutomatically(_ on: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = on
        installsAutomatically = on
    }

    /// Installs the downloaded update and relaunches.
    func restart() { installNow?() }

    /// Installs a downloaded update unless Headroom is busy or in use. Called when Headroom goes to the background and on each scan tick.
    func installIfIdle() {
        let model = AppModel.shared
        guard installNow != nil, model.sweep == nil, !model.scanning, !NSApp.isActive else { return }
        restart()
    }

    // MARK: SPUUpdaterDelegate

    /// Test hook: point a build at a local appcast. Updates still need the release key's signature.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["HEADROOM_FEED_URL"]
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        installNow = immediateInstallationBlock
        ready = item.displayVersionString
        installIfIdle()
        return true
    }

    // MARK: SPUStandardUserDriverDelegate

    /// A menu bar app should not throw an update window in front of other work. Scheduled finds show in the menu and Settings instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { if !handleShowingUpdate { available = version } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { available = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { available = nil }
    }
}
