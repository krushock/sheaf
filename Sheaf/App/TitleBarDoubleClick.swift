import AppKit

/// Makes a double click beside the document's name zoom the window, as it does
/// everywhere else on the title bar.
///
/// In a document window the name sits in a control that offers renaming and moving. That
/// control stretches from the name all the way to the toolbar's buttons, and a double
/// click on its empty part does nothing. The rest of the toolbar zooms or minimizes the
/// window, whichever the person chose in System Settings, so this does the same there.
enum TitleBarDoubleClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            MainActor.assumeIsolated { handle(event) }
            return event
        }
    }

    private static func handle(_ event: NSEvent) {
        guard event.clickCount == 2, let window = event.window, let frameView = window.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow),
              // The empty part of the title's row: the stretched control itself, not the
              // name or the buttons inside it.
              String(describing: type(of: hit)) == "NSToolbarPrimaryTitleContainerView"
        else { return }
        let frame = window.frame
        // After AppKit has had its turn. If it acted on the click after all, leave it at that.
        DispatchQueue.main.async {
            guard window.isVisible, !window.isMiniaturized, window.frame == frame else { return }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }
}
