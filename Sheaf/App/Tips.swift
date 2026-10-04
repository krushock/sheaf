import SwiftUI
import TipKit

/// Points out that the words on a page can be changed, which is not what most PDF apps do.
struct EditTip: Tip {
    var title: Text { Text("Change the Words Themselves") }
    var message: Text? { Text("Click Edit, then double-click any paragraph to type in it. Pictures can be moved and resized too.") }
    var image: Image? { Image(systemName: "character.cursor.ibeam") }
}

struct OrganizeTip: Tip {
    var title: Text { Text("Rearrange Pages") }
    var message: Text? { Text("See every page in a grid. Drag to reorder, and drop in PDFs or pictures from the Finder.") }
    var image: Image? { Image(systemName: "rectangle.grid.3x2") }
}

struct MarkupTip: Tip {
    var title: Text { Text("Highlight, Comment and Sign") }
    var message: Text? { Text("The markup tools add notes, shapes, stamps and your signature on top of the pages.") }
    var image: Image? { Image(systemName: "pencil.tip.crop.circle") }
}

/// Setting tips up, and showing them again.
enum SheafTips {
    /// Tips are left out of automated runs, where they would cover what is being checked.
    static var areEnabled: Bool {
        UserDefaults.standard.double(forKey: "SnapshotWindows") == 0
    }

    static func configure() {
        guard areEnabled else { return }
        try? Tips.configure([.displayFrequency(.daily)])
    }

    /// Forgets which tips were seen, so they come round again.
    static func showAgain() {
        try? Tips.resetDatastore()
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}
