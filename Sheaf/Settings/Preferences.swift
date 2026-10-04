import SheafKit
import SwiftUI

/// How pages are arranged in the viewer.
enum PageLayout: String, CaseIterable, Identifiable {
    case continuous, singlePage, twoPages

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .continuous: "Continuous Scroll"
        case .singlePage: "Single Page"
        case .twoPages: "Two Pages"
        }
    }
}

/// What the sidebar lists.
enum SidebarMode: String, CaseIterable, Identifiable {
    case thumbnails, tableOfContents, annotations

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .thumbnails: "Thumbnails"
        case .tableOfContents: "Table of Contents"
        case .annotations: "Highlights and Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .thumbnails: "square.grid.2x2"
        case .tableOfContents: "list.bullet.indent"
        case .annotations: "highlighter"
        }
    }
}

enum OpeningZoom: String, CaseIterable, Identifiable {
    case fitWidth, actualSize

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .fitWidth: "Fit to Window"
        case .actualSize: "Actual Size"
        }
    }
}

enum OpeningSidebar: String, CaseIterable, Identifiable {
    case hidden, thumbnails, tableOfContents

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .hidden: "Hidden"
        case .thumbnails: "Thumbnails"
        case .tableOfContents: "Table of Contents"
        }
    }
}

nonisolated enum NewDocumentPaper: String, CaseIterable, Identifiable, Sendable {
    case system, letter, a4

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Default Printer Paper"
        case .letter: "US Letter"
        case .a4: "A4"
        }
    }

    var pageSize: PageSize {
        switch self {
        case .letter: return .letter
        case .a4: return .a4
        case .system:
            let paper = NSPrintInfo.shared.paperSize
            return PageSize(width: paper.width, height: paper.height)
        }
    }
}

/// User defaults keys and typed readers for code outside SwiftUI views.
nonisolated enum Preferences {
    static let showWelcomeAtLaunch = "general.showWelcomeAtLaunch"
    static let askedAboutDefaultApp = "general.askedAboutDefaultApp"
    static let newDocumentPaper = "general.newDocumentPaper"
    static let pageLayout = "viewing.pageLayout"
    static let openingZoom = "viewing.openingZoom"
    static let openingSidebar = "viewing.openingSidebar"
    static let welcomeShowsGrid = "welcome.showsGrid"
    static let organizerPageSizeKey = "organizer.pageSize"
    static let highlightsFields = "forms.highlightsFields"
    static let pictureKeepsProportions = "editing.pictureKeepsProportions"

    /// Whether resizing a picture by a corner, or by typing one side, keeps its shape.
    static var pictureKeepsProportionsValue: Bool {
        UserDefaults.standard.object(forKey: pictureKeepsProportions) as? Bool ?? true
    }

    /// The width of a page in the organizer's grid.
    static var organizerPageSize: Double {
        let stored = UserDefaults.standard.double(forKey: organizerPageSizeKey)
        return stored > 0 ? min(max(stored, 90), 320) : 150
    }

    static func value<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap { T(rawValue: $0) } ?? fallback
    }
}
