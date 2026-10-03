import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launching or reactivating with no windows shows the Welcome window, not an
    /// untitled document.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    #if DEBUG
    // Scheduled before launch completes so it also fires while a launch-time alert is up.
    func applicationWillFinishLaunching(_ notification: Notification) {
        DebugSnapshot.scheduleIfRequested()
    }
    #endif
}
