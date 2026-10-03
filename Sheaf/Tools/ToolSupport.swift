import AppKit
import PDFKit
import SheafKit
import SwiftUI

/// Which pages a tool acts on.
struct PageScope: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case all, current, range

        var id: Self { self }
    }

    var kind = Kind.all
    var rangeText = ""

    /// The chosen page indexes in order, or `nil` while the range cannot be read.
    func indexes(pageCount: Int, current: Int) -> [Int]? {
        switch kind {
        case .all: Array(0..<pageCount)
        case .current: [current]
        case .range: (try? PageRanges.parse(rangeText, pageCount: pageCount)).map { Array(Set($0)).sorted() }
        }
    }
}

/// The "Pages" rows shared by the tool sheets.
struct PageScopeRows: View {
    @Binding var scope: PageScope
    let pageCount: Int
    let currentPage: Int

    var body: some View {
        Picker("Pages", selection: $scope.kind) {
            Text("All").tag(PageScope.Kind.all)
            Text("Current Page (\(currentPage + 1))").tag(PageScope.Kind.current)
            Text("Range").tag(PageScope.Kind.range)
        }
        if scope.kind == .range {
            TextField("Range", text: $scope.rangeText, prompt: Text("1-3, 5, 8-"))
            if !scope.rangeText.isEmpty, scope.indexes(pageCount: pageCount, current: currentPage) == nil {
                Text("Enter page numbers from 1 to \(pageCount), such as 1-3, 5.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// A page shown beside a tool's settings, so the result can be judged before it is applied.
struct PagePreview: View {
    let image: CGImage?
    var caption: LocalizedStringKey = "Preview"

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .background(.white)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.4))
    }
}

extension ViewerModel {
    /// A picture of one page with a change applied to it, without changing the document.
    func preview(ofPage index: Int, applying change: (inout PDFEditor, Int) throws -> Void) -> CGImage? {
        guard let editor = sheafDocument?.editor, pageIDs.indices.contains(index) else { return nil }
        // The page alone, in a document of its own, so the size of the whole does not matter.
        guard let single = try? editor.extractingPages([index]), let file = try? PDFFile(data: single) else { return nil }
        var copy = PDFEditor(file)
        do { try change(&copy, 0) } catch { return nil }
        guard let data = try? copy.serialized(), let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let scale = 900 / max(size.width, size.height, 1)
        return page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The page a tool's preview shows: the first of its pages at or after the one being read.
    func previewPage(for indexes: [Int]?) -> Int {
        guard let indexes, !indexes.isEmpty else { return currentPageIndex }
        return indexes.first { $0 >= currentPageIndex } ?? indexes[indexes.count - 1]
    }
}

/// Fonts offered for text that tools add to pages.
enum ToolFont: String, CaseIterable, Identifiable {
    case helvetica = "Helvetica", helveticaBold = "Helvetica-Bold"
    case helveticaNeue = "HelveticaNeue", helveticaNeueBold = "HelveticaNeue-Bold"
    case avenirNext = "AvenirNext-Regular", avenirNextBold = "AvenirNext-Bold"
    case times = "TimesNewRomanPSMT", timesBold = "TimesNewRomanPS-BoldMT"
    case georgia = "Georgia", georgiaBold = "Georgia-Bold"
    case courier = "CourierNewPSMT", courierBold = "CourierNewPS-BoldMT"
    case menlo = "Menlo-Regular"

    var id: Self { self }

    var title: String {
        switch self {
        case .helvetica: "Helvetica"
        case .helveticaBold: "Helvetica Bold"
        case .helveticaNeue: "Helvetica Neue"
        case .helveticaNeueBold: "Helvetica Neue Bold"
        case .avenirNext: "Avenir Next"
        case .avenirNextBold: "Avenir Next Bold"
        case .times: "Times New Roman"
        case .timesBold: "Times New Roman Bold"
        case .georgia: "Georgia"
        case .georgiaBold: "Georgia Bold"
        case .courier: "Courier New"
        case .courierBold: "Courier New Bold"
        case .menlo: "Menlo"
        }
    }
}

/// A slider with its value written beside it, as in the Format panel.
struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// Formats a byte count the way the Finder does.
func formattedSize(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// Asks for the password of a PDF that a tool was handed.
enum PasswordRequest {
    /// Asks until the password opens the document or the person gives up.
    ///
    /// - Returns: The opened document, or `nil` to leave it out.
    static func open(_ data: Data, named name: String, on window: NSWindow? = nil) -> PDFFile? {
        var wasWrong = false
        while true {
            guard let password = ask(named: name, wasWrong: wasWrong) else { return nil }
            if let file = try? PDFFile(data: data, password: password) { return file }
            wasWrong = true
        }
    }

    /// One round of asking. `nil` means the person chose to skip the document.
    static func ask(named name: String, wasWrong: Bool) -> String? {
        #if DEBUG
        // Lets automated runs answer, once, without a person at the keyboard.
        if !wasWrong, let answer = UserDefaults.standard.string(forKey: "SnapshotInsertPassword") { return answer }
        #endif
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(name)” is protected with a password.")
        alert.informativeText = wasWrong
            ? String(localized: "That password is not correct. Try again, or skip this document.")
            : String(localized: "Enter its password to use its pages.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Password")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
