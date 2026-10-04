import AppKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// A saved signature, drawn in whatever space it is given.
struct SignaturePreview: View {
    let signature: SavedSignature

    var body: some View {
        Group {
            switch signature.content {
            case .strokes(let strokes, let lineWidth):
                Canvas { context, size in
                    // As on the page: curves through the points, half the pen's width in from the edge.
                    let width = max(lineWidth * min(size.width, size.height), 1), margin = width / 2
                    for stroke in strokes {
                        let points = stroke.map { CGPoint(x: margin + $0.x * (size.width - width), y: margin + (1 - $0.y) * (size.height - width)) }
                        context.stroke(Path(PenStroke.path(through: points)), with: .foreground, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    }
                }
            case .shapes(let elements):
                Canvas { context, size in
                    var path = Path()
                    func place(_ point: PDFPoint) -> CGPoint { CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height) }
                    for element in elements {
                        switch element {
                        case .move(let point): path.move(to: place(point))
                        case .line(let point): path.addLine(to: place(point))
                        case .curve(let control1, let control2, let end): path.addCurve(to: place(end), control1: place(control1), control2: place(control2))
                        case .close: path.closeSubpath()
                        }
                    }
                    context.fill(path, with: .foreground)
                }
            case .image(let png):
                if let image = NSImage(data: png) {
                    Image(nsImage: image).resizable()
                }
            }
        }
        .aspectRatio(signature.aspectRatio, contentMode: .fit)
        .accessibilityLabel("Signature")
    }
}

/// The popover under the Sign button: saved signatures, and a way to make a new one.
struct SignaturePicker: View {
    @Bindable var viewer: ViewerModel
    private let store = SignatureStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.signatures.isEmpty {
                Text("No signatures yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            ForEach(store.signatures) { signature in
                HStack {
                    Button {
                        viewer.place(signature)
                        viewer.isSignaturePickerPresented = false
                    } label: {
                        SignaturePreview(signature: signature)
                            .frame(maxWidth: 190, maxHeight: 48)
                            .frame(maxWidth: .infinity)
                            .padding(6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    Button("Remove", systemImage: "xmark.circle.fill") { store.remove(signature) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove this signature")
                }
            }
            Divider()
            Button("Create Signature…") {
                viewer.isSignaturePickerPresented = false
                viewer.isSignatureCreatorPresented = true
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 270)
    }
}

/// The sheet for making a signature by drawing, typing or importing a picture.
struct SignatureCreator: View {
    let onCreate: (SavedSignature) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Method: Hashable {
        case draw, type, image
    }

    @State private var method = Method.draw
    @State private var strokes: [[CGPoint]] = []
    @State private var typedName = NSFullUserName()
    @State private var fontName = SignatureCreator.scriptFonts.first?.name ?? "Snell Roundhand"
    @State private var imported: SavedSignature?
    @State private var isImporting = false
    @State private var importFailed = false

    /// Handwriting-style typefaces that ship with macOS.
    static let scriptFonts: [(name: String, title: String)] = [
        ("SnellRoundhand", "Snell Roundhand"), ("SignPainter-HouseScript", "SignPainter"), ("BradleyHandITCTT-Bold", "Bradley Hand"),
        ("Noteworthy-Light", "Noteworthy"), ("SavoyeLetPlain", "Savoye"), ("Zapfino", "Zapfino"),
    ].filter { NSFont(name: $0.0, size: 12) != nil }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Method", selection: $method) {
                Text("Draw").tag(Method.draw)
                Text("Type").tag(Method.type)
                Text("Image").tag(Method.image)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Group {
                switch method {
                case .draw: drawing
                case .type: typing
                case .image: importing
                }
            }
            .frame(width: 440, height: 190)

            HStack {
                if method == .draw {
                    Button("Clear") { strokes = [] }
                        .disabled(strokes.isEmpty)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    if let signature = result { onCreate(signature) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result == nil)
            }
        }
        .padding(20)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { outcome in
            guard case .success(let url) = outcome else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            load(imageData: try? Data(contentsOf: url))
        }
        .alert("The picture could not be used.", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose a photo or scan of a signature in dark ink on light paper.")
        }
    }

    private var result: SavedSignature? {
        switch method {
        case .draw: SignatureMaker.signature(fromStrokes: strokes)
        case .type: SignatureMaker.signature(fromText: typedName, fontName: fontName)
        case .image: imported
        }
    }

    private var drawing: some View {
        SignaturePad(strokes: $strokes)
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay(alignment: .bottom) {
                VStack(spacing: 4) {
                    Divider().padding(.horizontal, 30)
                    Text("Sign with the mouse or trackpad")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 14)
                .allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private var typing: some View {
        VStack(spacing: 12) {
            Text(typedName.isEmpty ? " " : typedName)
                .font(.custom(fontName, size: 44))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            HStack {
                TextField("Name", text: $typedName)
                Picker("Typeface", selection: $fontName) {
                    ForEach(Self.scriptFonts, id: \.name) { Text($0.title).tag($0.name) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var importing: some View {
        VStack(spacing: 12) {
            Group {
                if let imported {
                    SignaturePreview(signature: imported).padding(16)
                } else {
                    ContentUnavailableView("No Picture", systemImage: "photo", description: Text("Use a photo or scan of your signature on white paper."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            // File > Import from iPhone or iPad delivers a photo here while this tab is showing.
            .importsItemProviders([.image]) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    Task { @MainActor in load(imageData: data) }
                }
                return true
            }
            Button("Choose Picture…") { isImporting = true }
        }
    }

    private func load(imageData: Data?) {
        if let imageData, let signature = SignatureMaker.signature(fromImageData: imageData) {
            imported = signature
        } else {
            importFailed = true
        }
    }
}

/// The line a pen leaves through the places it was at.
enum PenStroke {
    /// A curve through the middle of each stretch between two points, bending at the
    /// points themselves. This is how the engine draws strokes on the page too.
    static func path(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            // A dot, or a single straight stretch.
            path.addLine(to: points.last ?? first)
            return path
        }
        for index in 1..<points.count - 1 {
            let control = points[index], next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// A surface that records pen strokes drawn with the mouse.
struct SignaturePad: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]

    func makeNSView(context: Context) -> PadView {
        let view = PadView()
        view.onChange = { strokes = $0 }
        return view
    }

    func updateNSView(_ view: PadView, context: Context) {
        view.onChange = { strokes = $0 }
        if view.strokes != strokes {
            view.strokes = strokes
            view.needsDisplay = true
        }
    }

    final class PadView: NSView {
        var strokes: [[CGPoint]] = []
        var onChange: (([[CGPoint]]) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            strokes.append([convert(event.locationInWindow, from: nil)])
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard !strokes.isEmpty else { return }
            strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            onChange?(strokes)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            // Drawn the way it will look on the page: as curves, not the straight
            // stretches between the places the mouse was reported at.
            context.setStrokeColor(NSColor.labelColor.cgColor)
            context.setLineWidth(2.5)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in strokes {
                context.addPath(PenStroke.path(through: stroke))
                context.strokePath()
            }
        }
    }
}
