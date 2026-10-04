import SwiftUI

// Updates come through Sparkle, which is not part of the project until its package is
// added (see RELEASING.md). With the package present this file gives the app a
// "Check for Updates…" command; without it, nothing here is compiled and nothing shows.

#if canImport(Sparkle)
import Sparkle

/// Owns Sparkle's updater and says when a check can be started.
@Observable
final class UpdaterModel {
    static let shared = UpdaterModel()

    @ObservationIgnored private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// The "Check for Updates…" item under the app menu.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdaterModel.shared.checkForUpdates() }
                .disabled(!UpdaterModel.shared.canCheck)
        }
    }
}
#else
/// No updater in this build.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {}
    }
}
#endif
