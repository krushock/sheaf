import SheafKit
import SwiftUI

/// A paper size offered for new pages.
nonisolated enum Paper: String, CaseIterable, Identifiable {
    case a3, a4, a5, letter, legal, tabloid

    var id: Self { self }

    var title: String {
        switch self {
        case .a3: String(localized: "A3")
        case .a4: String(localized: "A4")
        case .a5: String(localized: "A5")
        case .letter: String(localized: "US Letter")
        case .legal: String(localized: "US Legal")
        case .tabloid: String(localized: "Tabloid")
        }
    }

    /// Upright.
    var size: PageSize {
        switch self {
        case .a3: .a3
        case .a4: .a4
        case .a5: .a5
        case .letter: .letter
        case .legal: .legal
        case .tabloid: .tabloid
        }
    }

    /// Whether lengths are shown in inches here, not millimeters.
    static var usesInches: Bool { Locale.current.measurementSystem == .us }

    /// The papers, those of this part of the world first.
    static var ordered: [Paper] {
        usesInches ? [.letter, .legal, .tabloid, .a3, .a4, .a5] : [.a3, .a4, .a5, .letter, .legal, .tabloid]
    }

    /// The paper a size is, either way up, give or take what rounding leaves.
    static func matching(_ size: PageSize) -> (paper: Paper, isLandscape: Bool)? {
        for paper in allCases {
            if abs(paper.size.width - size.width) <= 2, abs(paper.size.height - size.height) <= 2 { return (paper, false) }
            if abs(paper.size.height - size.width) <= 2, abs(paper.size.width - size.height) <= 2 { return (paper, true) }
        }
        return nil
    }

    /// What to call a size: the paper it is, or its measurements.
    static func name(of size: PageSize) -> String {
        guard let (paper, isLandscape) = matching(size) else { return measurements(of: size) }
        return isLandscape ? String(localized: "\(paper.title) Landscape") : paper.title
    }

    /// A size in millimeters or inches, such as "210 × 297 mm".
    static func measurements(of size: PageSize) -> String {
        let unit: UnitLength = usesInches ? .inches : .millimeters
        let digits = usesInches ? 0...2 : 0...0
        // A point is a seventy-second of an inch.
        let width = Measurement(value: size.width / 72, unit: UnitLength.inches).converted(to: unit)
        let height = Measurement(value: size.height / 72, unit: UnitLength.inches).converted(to: unit)
        let last = height.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(digits))))
        return "\(width.value.formatted(.number.precision(.fractionLength(digits)))) × \(last)"
    }
}

/// A size offered for a blank page.
struct BlankPageChoice: Identifiable {
    var title: String
    var size: PageSize

    var id: String { title }
}

/// The menu that inserts a blank page: the sizes the document has, the common papers,
/// and a sheet for anything else.
struct BlankPageMenu: View {
    let title: LocalizedStringKey
    let viewer: ViewerModel
    /// Where the page goes. `nil` is after the selected page.
    var index: Int?

    init(_ title: LocalizedStringKey, viewer: ViewerModel, index: Int? = nil) {
        self.title = title
        self.viewer = viewer
        self.index = index
    }

    var body: some View {
        Menu(title) {
            ForEach(viewer.documentPageSizes(forBlankPageAt: index)) { choice in
                Button(choice.title) { viewer.insertBlankPage(at: index, size: choice.size) }
            }
            Divider()
            ForEach(Paper.ordered) { paper in
                Button(paper.title) { viewer.insertBlankPage(at: index, size: paper.size) }
            }
            Divider()
            Button("Other Size…") { viewer.chooseBlankPageSize(at: index) }
        }
    }
}

/// A blank page of any size: a paper either way up, or measurements typed in.
struct BlankPageSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    /// `nil` is a size typed in.
    @State private var paper: Paper?
    @State private var isLandscape = false
    /// In points, as the page will be.
    @State private var width = PageSize.a4.width
    @State private var height = PageSize.a4.height

    private var unit: UnitLength { Paper.usesInches ? .inches : .millimeters }
    private var pointsPerUnit: Double { Paper.usesInches ? 72 : 72 / 25.4 }
    /// What a PDF page may measure: from a quarter of an inch to 200 inches.
    private let limits = 18.0...14_400.0

    var body: some View {
        Form {
            Section {
                Picker("Paper size", selection: paperBinding) {
                    ForEach(Paper.ordered) { Text($0.title).tag(Paper?.some($0)) }
                    Divider()
                    Text("Custom").tag(Paper?.none)
                }
                Picker("Orientation", selection: orientationBinding) {
                    Label("Portrait", systemImage: "rectangle.portrait").tag(false)
                    Label("Landscape", systemImage: "rectangle").tag(true)
                }
                .pickerStyle(.segmented)
                LabeledContent("Size") {
                    HStack(spacing: 6) {
                        length("Width", $width)
                        Text("×").foregroundStyle(.secondary)
                        length("Height", $height)
                        Text(unit.symbol).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("The page goes after page \(max(position, 1)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // It starts as the page it will follow.
            guard let size = viewer.displaySize(ofPageAt: max(position - 1, 0)) else { return }
            set(size)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Insert") {
                    viewer.insertBlankPage(at: viewer.blankPagePosition, size: PageSize(width: width, height: height))
                    dismiss()
                }
            }
        }
    }

    private var position: Int { viewer.blankPagePosition ?? viewer.insertionIndex }

    private func set(_ size: PageSize) {
        width = min(max(size.width, limits.lowerBound), limits.upperBound)
        height = min(max(size.height, limits.lowerBound), limits.upperBound)
        let match = Paper.matching(PageSize(width: width, height: height))
        paper = match?.paper
        isLandscape = match?.isLandscape ?? (width > height)
    }

    private var paperBinding: Binding<Paper?> {
        Binding(
            get: { paper },
            set: { chosen in
                paper = chosen
                guard let chosen else { return }
                (width, height) = isLandscape ? (chosen.size.height, chosen.size.width) : (chosen.size.width, chosen.size.height)
            }
        )
    }

    private var orientationBinding: Binding<Bool> {
        Binding(
            get: { isLandscape },
            set: { landscape in
                guard landscape != isLandscape else { return }
                isLandscape = landscape
                // The same paper, turned.
                if (width > height) != landscape { (width, height) = (height, width) }
            }
        )
    }

    /// One side of the page, shown in millimeters or inches.
    private func length(_ title: LocalizedStringKey, _ points: Binding<Double>) -> some View {
        let digits = Paper.usesInches ? 0...2 : 0...1
        return TextField(title, value: Binding(
            get: { points.wrappedValue / pointsPerUnit },
            set: { entered in
                guard entered.isFinite, entered > 0 else { return }
                points.wrappedValue = min(max(entered * pointsPerUnit, limits.lowerBound), limits.upperBound)
                set(PageSize(width: width, height: height))
            }
        ), format: .number.precision(.fractionLength(digits)))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .accessibilityLabel(title)
    }
}
