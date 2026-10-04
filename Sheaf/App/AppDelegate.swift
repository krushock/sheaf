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
        TitleBarDoubleClick.install()
        DefaultPDFApp.askOnceIfNeeded()
    }

    // Before any document is read: a file opened from Mail is noted as such while it is read.
    func applicationWillFinishLaunching(_ notification: Notification) {
        SavePanelOptions.installAtLaunch()
        #if DEBUG
        // Scheduled before launch completes so it also fires while a launch-time alert is up.
        DebugSnapshot.scheduleIfRequested()
        if UserDefaults.standard.bool(forKey: "SnapshotDocumentClasses") {
            // What SwiftUI has set up by now, to know where a hook can go.
            let controller = NSDocumentController.shared
            let kind: AnyClass? = controller.documentClass(forType: "com.adobe.pdf")
            print("CLASSES controller \(type(of: controller)) document \(kind.map { NSStringFromClass($0) } ?? "none")")
            var current: AnyClass? = kind
            while let look = current, look != NSObject.self {
                var count: UInt32 = 0
                let methods = class_copyMethodList(look, &count)
                var names: [String] = []
                for index in 0..<Int(count) { if let method = methods?[index] { names.append(NSStringFromSelector(method_getName(method))) } }
                free(methods)
                let relevant = names.filter { $0.contains("read") || $0.hasPrefix("init") || $0.contains("Save") || $0.contains("canClose") || $0.contains("duplicate") || $0.contains("fileURL") || $0.contains("Draft") }
                print("CLASSES   \(NSStringFromClass(look)): \(count) methods, of interest \(look == NSDocument.self ? ["(the base class)"] : relevant.sorted())")
                if look == NSDocument.self { break }
                current = class_getSuperclass(look)
            }
            var count: UInt32 = 0
            let methods = class_copyMethodList(object_getClass(controller), &count)
            var names: [String] = []
            for index in 0..<Int(count) { if let method = methods?[index] { names.append(NSStringFromSelector(method_getName(method))) } }
            free(methods)
            print("CLASSES   controller methods \(names.sorted())")
        }
        #endif
    }
}
