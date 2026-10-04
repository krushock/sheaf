#if DEBUG
import AppIntents
import AppKit
import PDFKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// Developer aid for checking the UI without screen-recording permission.
///
/// Run the binary with `-SnapshotWindows <seconds>` and stdout redirected to a file. After
/// the delay the app draws each of its windows into a PNG and prints one line per window:
/// `SNAPSHOT <title>\t<base64 PNG>`. `Scripts/snapshot.sh` drives this.
///
/// App flags: `-SnapshotQuits YES` quits afterwards, `-SnapshotNewDocument YES` performs
/// File > New first, `-SnapshotClearsRecents YES` empties Open Recent, `-SnapshotMenus YES`
/// lists the menu bar, `-SnapshotSettings YES` opens Settings.
///
/// Viewer flags, applied to every document window: `-SnapshotPassword <text>`,
/// `-SnapshotSidebar hidden|thumbnails|tableOfContents|annotations`, `-SnapshotSearch <text>`,
/// `-SnapshotLayout continuous|singlePage|twoPages`, `-SnapshotPage <number>`,
/// `-SnapshotGoToPage YES`, `-SnapshotExport <extension>` (prints `EXPORT` lines),
/// `-SnapshotAction print|exportPanel|duplicate|revert|saveAs|saveWith:<archival+screen+jpeg+password>`,
/// `-SnapshotMarkup tools,restyle,undo,redo,save,flatten,bookmarks,reply,existing,mouse,typing,
/// signatures,signatureSheet` (steps run in order),
/// `-SnapshotPages organize,select:1-3,rotate,move:1,duplicate,delete,blank[:<paper>|:sheet],split,insert:<path>,extract,
/// copyPaste,sheet:<name>,watermark,numbers,protect:<password>,unprotect,reduce,info:<title>,undo,redo,saved`
/// (steps run a quarter of a second apart),
/// `-SnapshotEdit on,select:<text>,open:<text>,type:<text>,commit,swap:<old>:<new>,move:<dx>:<dy>,nudge:<dx>:<dy>,
/// delete,size:<pt>,font:<name>,color,newtext:<x>:<y>:<text>,picture:<path>,image,resize:<dx>:<dy>,turn:<degrees>[:shift|hold],
/// pointer:<handle number>[:cmd],pick:<picture number>,restack:<toFront|forward|backward|toBack>,align:<left|center|…>,
/// stretch:<left|right>:<dx>,editorSide:<left|right>:<dx>,flip:<h|v>,opacity:<0…1>,duplicate,cut,copy,link,background,mask[:<x>:<y>:<w>:<h>[:hold]],unmask,menu,paste:<text>,
/// find:<text>:<replacement>,next,replace,replaceAll,mark:<pattern>,redact:<x1>:<y1>:<x2>:<y2>,preview,apply,ocr,
/// undo,undoOne,redo,saved:<text>` (steps run a third of a second apart),
/// `-SnapshotForms fill,tab,editor:<field>,date,build,select:<field>,move,delete,detect,done,reset,flatten,undo,saved`.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        let delay = UserDefaults.standard.double(forKey: "SnapshotWindows")
        guard delay > 0 else { return }
        // Line-buffered, so output survives if the app has to be killed.
        setvbuf(stdout, nil, _IOLBF, 0)
        // A timer in the common modes also fires while an alert runs modally.
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        if UserDefaults.standard.bool(forKey: "SnapshotNewDocument") {
            DispatchQueue.main.async { NSDocumentController.shared.newDocument(nil) }
        }
    }

    /// Opens Settings once when asked to. Views pass in the action from their environment.
    static func openSettingsIfRequested(_ openSettings: OpenSettingsAction) {
        guard UserDefaults.standard.bool(forKey: "SnapshotSettings"), !didOpenSettings else { return }
        didOpenSettings = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openSettings() }
    }

    private static var didRunMarkup = false

    /// Drives the markup tools the way the mouse would, and reports what the document holds.
    private static func runMarkup(_ step: String, _ viewer: ViewerModel) {
        guard let document = viewer.sheafDocument else { return }
        func drag(_ tool: MarkupTool, _ points: [(Double, Double)], page: Int = 0) {
            viewer.tool = tool
            guard let first = points.first else { return }
            _ = viewer.mouseDown(at: PDFPoint(x: first.0, y: first.1), pageIndex: page, clickCount: 1)
            for point in points.dropFirst() { viewer.mouseDragged(to: PDFPoint(x: point.0, y: point.1)) }
            viewer.mouseUp()
        }
        func report(_ label: String) {
            let kinds = ((try? document.editor?.annotations(onPageAt: 0)) ?? []).map(\.kind.rawValue)
            let shown = viewer.document?.page(at: 0)?.annotations.count ?? -1
            print("MARKUP \(label): \(kinds.count) annotations \(kinds), \(shown) on screen, undo=\(document.undoManager?.canUndo ?? false)")
            for annotation in ((try? document.editor?.annotations(onPageAt: 0)) ?? []) where annotation.kind == .stamp {
                let displayed = annotation.objectID.flatMap { document.displayedAnnotation($0, onPage: 0) }
                let shownBounds = displayed?.bounds
                // Read by PDFKit from the file's own bytes, which is sharp, or drawn by the app, which is not.
                print("MARKUP   stamp rect \(annotation.rect) shown at \(String(describing: shownBounds)) content=\(annotation.stamp != nil) drawn by \(displayed.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
        }
        switch step {
        case "tools":
            viewer.isMarkupVisible = true
            drag(.rectangle, [(320, 330), (400, 380), (470, 420)])
            drag(.ellipse, [(480, 330), (560, 400)])
            drag(.arrow, [(90, 420), (200, 360), (260, 340)])
            drag(.draw, [(90, 300), (120, 330), (150, 290), (180, 325), (210, 295)])
            drag(.link, [(90, 240), (230, 264)])
            drag(.note, [(545, 700)])
            // A text box: drag it out, type, and click away.
            drag(.text, [(320, 280), (540, 240)])
            viewer.pdfView.debugType("Text typed into a box. Юникод тоже.")
            viewer.pdfView.endTextEditing(commit: true)
            // Mark two lines of the page's text.
            if let page = viewer.document?.page(at: 0) {
                for (kind, rect) in [(Annotation.Kind.highlight, CGRect(x: 72, y: 620, width: 468, height: 40)), (.underline, CGRect(x: 72, y: 690, width: 120, height: 30))] {
                    viewer.pdfView.setCurrentSelection(page.selection(for: rect), animate: false)
                    viewer.applyTextMarkup(kind)
                }
            }
            viewer.placeStamp(.text("Approved"), width: 170, aspectRatio: 3.7, color: .green, name: "Add Stamp")
            if let signature = SignatureMaker.signature(fromText: "Valery B.", fontName: "SnellRoundhand") { viewer.place(signature) }
            // Move the signature down by dragging it, then pick the rectangle.
            if let selection = viewer.selection, let annotation = viewer.selectedAnnotation {
                let middle = (annotation.rect.x + annotation.rect.width / 2, annotation.rect.y + annotation.rect.height / 2)
                viewer.tool = .select
                _ = viewer.mouseDown(at: PDFPoint(x: middle.0, y: middle.1), pageIndex: selection.pageIndex, clickCount: 1)
                viewer.mouseDragged(to: PDFPoint(x: middle.0 + 40, y: middle.1 - 150))
                viewer.mouseDragged(to: PDFPoint(x: middle.0 + 90, y: middle.1 - 250))
                viewer.mouseUp()
            }
            _ = viewer.mouseDown(at: PDFPoint(x: 395, y: 418), pageIndex: 0, clickCount: 1)
            viewer.mouseUp()
            viewer.isInspectorVisible = true
            report("after tools")
        case "restyle":
            viewer.updateSelection("Change Color") { $0.color = .blue }
            viewer.updateSelection("Change Fill") { $0.fillColor = PDFColor(red: 0.8, green: 0.9, blue: 1) }
            viewer.updateSelection("Change Line Width") { $0.lineWidth = 5 }
            report("after restyle")
        case "undo":
            var steps = 0
            while document.undoManager?.canUndo == true, steps < 100 {
                document.undoManager?.undo()
                steps += 1
            }
            report("after \(steps) undos")
        case "redo":
            var steps = 0
            while document.undoManager?.canRedo == true, steps < 100 {
                document.undoManager?.redo()
                steps += 1
            }
            report("after \(steps) redos")
        case "save":
            do {
                let saved = document.currentData
                let file = try PDFFile(data: saved, password: document.password)
                let kinds = try file.annotations(forPage: try file.pageIDs()[0]).map(\.kind.rawValue)
                let reader = PDFDocument(data: saved)
                if let password = document.password { reader?.unlock(withPassword: password) }
                let types = reader?.page(at: 0)?.annotations.map { $0.type ?? "?" } ?? []
                print("MARKUP saved: \(saved.count) bytes, keeps original=\(saved.prefix(document.contents.data.count) == document.contents.data), engine reads \(kinds), PDFKit reads \(types), outline \(try file.outline().map(\.title))")
            } catch {
                print("MARKUP save failed: \(error)")
            }
        case "flatten":
            viewer.flattenAnnotations()
            report("after flatten")
        case "bookmarks":
            viewer.addBookmark()
            viewer.goToPage(index: min(2, viewer.pageCount - 1))
            viewer.addBookmark()
            viewer.renameBookmark(at: [0], to: "Renamed first bookmark")
            print("MARKUP bookmarks: \(viewer.outline.map { "\($0.title)@\($0.pageIndex ?? -1)" })")
        case "mouse":
            // Real mouse events through the view, to check coordinates and event handling.
            guard let page = viewer.document?.page(at: 0), let window = viewer.pdfView.window else { return }
            viewer.isMarkupVisible = true
            viewer.tool = .rectangle
            func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent? {
                let inView = viewer.pdfView.convert(CGPoint(x: x, y: y), from: page)
                let inWindow = viewer.pdfView.convert(inView, to: nil)
                return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = event(.leftMouseDown, 100, 400), let move = event(.leftMouseDragged, 200, 330), let up = event(.leftMouseUp, 260, 300) {
                viewer.pdfView.mouseDown(with: down)
                viewer.pdfView.mouseDragged(with: move)
                if let end = event(.leftMouseDragged, 260, 300) { viewer.pdfView.mouseDragged(with: end) }
                viewer.pdfView.mouseUp(with: up)
            }
            let made = ((try? document.editor?.annotations(onPageAt: 0)) ?? []).last
            print("MARKUP mouse: made \(made?.kind.rawValue ?? "nothing") at \(made.map { "\(Int($0.rect.x)),\(Int($0.rect.y)) \(Int($0.rect.width))x\(Int($0.rect.height))" } ?? "-"), selected=\(viewer.selection != nil), tool=\(viewer.tool.rawValue)")
        case "typing":
            // Leave a text box open for editing, to see the editor on screen.
            if let box = ((try? document.editor?.annotations(onPageAt: 0)) ?? []).first(where: { $0.kind == .freeText }) {
                viewer.beginTextEditing(box, pageIndex: 0, isNew: false)
                viewer.pdfView.debugType("Editing this text in place")
            }
        case "drawn":
            // A signature as the mouse draws one: a few dozen points along loops, not a smooth curve.
            viewer.isMarkupVisible = true
            var stroke: [CGPoint] = []
            for step in 0...46 {
                let t = Double(step) / 46
                stroke.append(CGPoint(x: 20 + 300 * t + 22 * sin(t * 26), y: 80 + 46 * sin(t * 19) * (1 - 0.5 * t)))
            }
            if let signature = SignatureMaker.signature(fromStrokes: [stroke, [CGPoint(x: 40, y: 40), CGPoint(x: 150, y: 52), CGPoint(x: 330, y: 44)]]) { viewer.place(signature) }
            viewer.selection = nil
            report("after a drawn signature")
            if UserDefaults.standard.bool(forKey: "SnapshotLayers") {
                // How PDFKit has laid its drawing out in layers, a moment later when it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    func walk(_ layer: CALayer, _ depth: Int) {
                        guard depth < 14 else { return }
                        let contents = layer.contents.map { value -> String in
                            if CFGetTypeID(value as CFTypeRef) == CGImage.typeID { let image = value as! CGImage; return "image \(image.width)x\(image.height)" }
                            return String(describing: type(of: value))
                        } ?? "none"
                        print("LAYER \(String(repeating: " ", count: depth))\(type(of: layer)) delegate=\(layer.delegate.map { String(describing: type(of: $0)) } ?? "-") bounds=\(layer.bounds.size) scale=\(layer.contentsScale) hidden=\(layer.isHidden) opacity=\(layer.opacity) contents=\(contents) sub=\(layer.sublayers?.count ?? 0)")
                        for sublayer in layer.sublayers ?? [] { walk(sublayer, depth + 1) }
                    }
                    if let layer = viewer.pdfView.layer { walk(layer, 0) }
                }
            }
        case "signatures":
            viewer.isMarkupVisible = true
            viewer.isSignaturePickerPresented = true
        case "signatureSheet":
            viewer.isMarkupVisible = true
            viewer.isSignatureCreatorPresented = true
        case "existing":
            // Change, then delete, annotations that came with the file.
            let before = (try? document.editor?.annotations(onPageAt: 0)) ?? []
            if let highlight = before.first(where: { $0.kind == .highlight }), let id = highlight.objectID {
                viewer.select(AnnotationSelection(pageIndex: 0, id: id))
                viewer.updateSelection("Change Color") { $0.color = .pink }
                report("recolored a highlight from the file")
            }
            if let link = before.first(where: { $0.kind == .link }), let id = link.objectID {
                viewer.delete(AnnotationSelection(pageIndex: 0, id: id))
                report("deleted a link from the file")
            }
        case "reply":
            if let note = (try? document.editor?.annotations(onPageAt: 0))?.first(where: { $0.kind == .note }), let id = note.objectID {
                viewer.select(AnnotationSelection(pageIndex: 0, id: id))
                viewer.updateSelection("Edit Comment") { $0.contents = "Is this figure right?" }
                viewer.addReply("Yes, checked against the source.", to: AnnotationSelection(pageIndex: 0, id: id))
            }
            viewer.showSidebar(.annotations)
            report("after reply")
        default:
            print("MARKUP unknown step \(step)")
        }
    }

    /// Set by the first window to appear, so steps can open the tool windows.
    static var openWindow: OpenWindowAction?
    private static var didRunPages = false
    private static var viewers: [ViewerModel] = []

    /// Drives the page organizer and the file tools, and reports what the document holds.
    private static func runPages(_ step: String, _ viewer: ViewerModel) {
        guard let document = viewer.sheafDocument else { return }
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        func report(_ label: String) {
            let editor = document.editor
            let count = (try? editor?.pageCount()) ?? -1
            let shapes = (0..<max(count, 0)).map { index -> String in
                guard let geometry = try? editor?.geometry(ofPageAt: index) else { return "?" }
                return "\(Int(geometry.displaySize.width))x\(Int(geometry.displaySize.height))@\(geometry.rotation)"
            }
            print("PAGES \(label): \(count) pages \(shapes), picked \(viewer.targetPageIndexes), bytes \(document.currentData.count), undo=\(document.undoManager?.canUndo ?? false), password=\(document.password != nil), encrypted=\(editor?.base.isEncrypted ?? false)")
        }
        func pick(_ indexes: [Int]) {
            viewer.pageSelection = Set(indexes.filter { viewer.pageIDs.indices.contains($0) }.map { viewer.pageIDs[$0] })
        }
        switch parts[0] {
        case "organize": viewer.isOrganizing = true
        case "close": viewer.isOrganizing = false
        case "select": pick(argument.split(separator: "-").compactMap { Int($0) }.map { $0 - 1 })
        case "size": viewer.organizerPageSize = Double(argument) ?? 150
        case "rotate": viewer.rotatePages(viewer.targetPageIndexes, by: 90)
        case "duplicate": viewer.duplicatePages(viewer.targetPageIndexes)
        case "delete": viewer.deletePages(viewer.targetPageIndexes)
        case "blank":
            // `blank:a3` and the like pick a paper, `blank:sheet` shows the sheet for any size.
            if argument == "sheet" {
                viewer.chooseBlankPageSize()
            } else {
                viewer.insertBlankPage(size: Paper(rawValue: argument)?.size)
            }
            print("PAGES blank page menu: \(viewer.documentPageSizes().map(\.title)) then \(Paper.ordered.map(\.title))")
        case "split": viewer.splitPagesInHalf(viewer.targetPageIndexes, direction: .vertical)
        case "move": viewer.movePages(viewer.targetPageIndexes, to: (Int(argument) ?? 1) - 1)
        case "insert": viewer.insertFiles([URL(fileURLWithPath: argument)], at: viewer.insertionIndex)
        case "extract": viewer.extractPages(viewer.targetPageIndexes)
        case "copyPaste":
            viewer.copyPages(viewer.targetPageIndexes)
            viewer.pastePages()
        case "sheet": viewer.activeSheet = ToolSheet(rawValue: argument)
        case "watermark":
            var mark = Watermark(content: .text(argument.isEmpty ? "Draft" : argument))
            mark.color = .red
            document.apply("Add Watermark") { editor, effect in
                try editor.addWatermark(mark)
                effect.reloadsDisplay = true
                effect.pages = Set(0..<(try editor.pageCount()))
            }
        case "numbers":
            var spec = HeaderFooter()
            spec.footer.center = "Page {page} of {pages}"
            spec.header.right = "{name}"
            document.apply("Add Header and Footer") { editor, effect in
                try editor.addHeaderFooter(spec, documentName: viewer.documentName)
                effect.reloadsDisplay = true
                effect.pages = Set(0..<(try editor.pageCount()))
            }
        case "protect":
            if let data = try? document.editor?.rewritten(protection: .password(user: argument)) {
                print("PAGES protect: \(document.replaceContents("Set Password", with: data, password: argument))")
            }
        case "unprotect":
            if let data = try? document.editor?.rewritten(protection: .none) {
                print("PAGES unprotect: \(document.replaceContents("Remove Password", with: data, password: nil))")
            }
        case "reduce":
            let source = Toolbox.Source(data: document.currentData, name: "debug", password: document.password)
            if let data = try? Toolbox.compress(source, options: .balanced) {
                print("PAGES reduce: \(source.data.count) to \(data.count), replaced \(document.replaceContents("Reduce File Size", with: data, password: document.password))")
            }
        case "info":
            document.apply("Change Document Info") { editor, _ in
                var info = try editor.info()
                info.title = argument
                try editor.setInfo(info)
            }
            print("PAGES info: \((try? document.editor?.info().title) ?? "nil")")
        case "undo":
            var steps = 0
            while document.undoManager?.canUndo == true, steps < (Int(argument) ?? 100) {
                document.undoManager?.undo()
                steps += 1
            }
        case "redo":
            var steps = 0
            while document.undoManager?.canRedo == true, steps < (Int(argument) ?? 100) {
                document.undoManager?.redo()
                steps += 1
            }
        case "merge":
            ToolInbox.shared.mergeURLs = argument.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            openWindow?(id: MergeWindow.windowID)
        case "images":
            ToolInbox.shared.imageURLs = argument.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            openWindow?(id: ImagesWindow.windowID)
        case "write":
            // What saving would write, to a file.
            do {
                try document.currentData.write(to: URL(fileURLWithPath: argument))
                print("PAGES wrote \(document.currentData.count) bytes")
            } catch {
                print("PAGES write failed: \(error)")
            }
        case "saved":
            // What saving would write, as PDFKit and the engine read it.
            let saved = document.currentData
            let reader = PDFDocument(data: saved)
            let locked = reader?.isLocked ?? false
            if let password = document.password { reader?.unlock(withPassword: password) }
            let file = try? PDFFile(data: saved, password: document.password)
            print("PAGES saved: \(saved.count) bytes, PDFKit \(reader?.pageCount ?? -1) pages locked=\(locked), engine \((try? file?.pageIDs().count) ?? -1) pages, title \((try? file?.info().title) ?? "nil"), outline \((try? file?.outline().map(\.title)) ?? [])")
        case "intents":
            let data = document.currentData
            Task { await runIntents(on: data) }
        case "report": break
        default: print("PAGES unknown step \(step)")
        }
        report("after \(step)")
    }

    /// Performs each Shortcuts action the way Shortcuts would, and reports what comes back.
    private static func runIntents(on data: Data) async {
        func describe(_ file: IntentFile, password: String? = nil) -> String {
            guard file.type?.conforms(to: .pdf) == true else { return "\(file.filename) \(file.data.count) bytes" }
            let reader = PDFDocument(data: file.data)
            let locked = reader?.isLocked ?? false
            if let password { reader?.unlock(withPassword: password) }
            return "\(file.filename) \(file.data.count) bytes, \(reader?.pageCount ?? -1) pages, locked=\(locked), rotation \(reader?.page(at: 0)?.rotation ?? -1)"
        }
        let input = IntentFile(data: data, filename: "Sample.pdf", type: .pdf)
        do {
            let merge = MergePDFsIntent()
            merge.files = [input, input]
            merge.bookmarks = true
            print("INTENT merge: \(describe(try await merge.perform().value!))")

            let split = SplitPDFIntent()
            split.file = input
            split.size = 2
            print("INTENT split: \(try await split.perform().value!.map { describe($0) })")

            let extract = ExtractPagesIntent()
            extract.file = input
            extract.pages = "2-3"
            print("INTENT extract: \(describe(try await extract.perform().value!))")

            let reduce = ReduceFileSizeIntent()
            reduce.file = input
            reduce.level = .balanced
            print("INTENT reduce: \(describe(try await reduce.perform().value!))")

            let toImages = PDFToImagesIntent()
            toImages.file = input
            toImages.format = .jpeg
            toImages.resolution = 72
            let pictures = try await toImages.perform().value!
            print("INTENT images: \(pictures.map { describe($0) })")

            let fromImages = ImagesToPDFIntent()
            fromImages.images = pictures
            fromImages.paper = .a4
            fromImages.straightens = false
            print("INTENT from images: \(describe(try await fromImages.perform().value!))")

            let watermark = AddWatermarkIntent()
            watermark.file = input
            watermark.text = "Draft"
            watermark.opacity = 0.3
            watermark.isTiled = true
            print("INTENT watermark: \(describe(try await watermark.perform().value!))")

            let numbers = AddPageNumbersIntent()
            numbers.file = input
            numbers.text = "{page} / {pages}"
            numbers.firstNumber = 1
            print("INTENT numbers: \(describe(try await numbers.perform().value!))")

            let rotate = RotatePDFPagesIntent()
            rotate.file = input
            rotate.turns = 1
            rotate.pages = "1"
            print("INTENT rotate: \(describe(try await rotate.perform().value!))")

            let protect = ProtectPDFIntent()
            protect.file = input
            protect.newPassword = "secret"
            let protected = try await protect.perform().value!
            print("INTENT protect: \(describe(protected, password: "secret"))")

            let remove = RemovePDFPasswordIntent()
            remove.file = protected
            remove.password = "secret"
            print("INTENT remove password: \(describe(try await remove.perform().value!))")

            let wrong = RemovePDFPasswordIntent()
            wrong.file = protected
            wrong.password = "nope"
            do {
                _ = try await wrong.perform()
                print("INTENT wrong password: accepted")
            } catch {
                print("INTENT wrong password: \(error.localizedDescription)")
            }
        } catch {
            print("INTENT failed: \(error)")
        }
    }

    private static var didRunForms = false

    /// Fills in and builds forms the way the mouse and keyboard would, and reports the fields.
    private static func runForms(_ step: String, _ viewer: ViewerModel) {
        guard let document = viewer.sheafDocument else { return }
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        func report(_ label: String) {
            let fields = viewer.formFields.map { field in
                "\(field.fullName)[\(field.kind.rawValue)]=\(field.value.replacingOccurrences(of: "\n", with: "⏎"))" + (field.widgets.count > 1 ? "x\(field.widgets.count)" : "")
            }
            print("FORMS \(label): \(fields.count) fields \(fields), on screen \(viewer.document?.page(at: 0)?.annotations.count ?? -1), undo=\(document.undoManager?.canUndo ?? false)")
        }
        func center(_ name: String, widget: Int = 0) -> (PDFPoint, Int)? {
            guard let field = viewer.formFields.first(where: { $0.fullName == name }), field.widgets.indices.contains(widget),
                  let page = field.widgets[widget].pageIndex else { return nil }
            let rect = field.widgets[widget].rect
            return (PDFPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2), page)
        }
        /// A click on a field, through the same code the mouse reaches.
        func click(_ name: String, widget: Int = 0) {
            guard let (point, page) = center(name, widget: widget) else { return print("FORMS no field \(name)") }
            viewer.pdfView.endFieldEditing(commit: true)
            _ = viewer.mouseDown(at: point, pageIndex: page, clickCount: 1)
            viewer.mouseUp()
        }
        func drag(_ tool: FormTool, _ from: (Double, Double), _ to: (Double, Double)) {
            viewer.formTool = tool
            _ = viewer.mouseDown(at: PDFPoint(x: from.0, y: from.1), pageIndex: 0, clickCount: 1)
            viewer.mouseDragged(to: PDFPoint(x: to.0, y: to.1))
            viewer.mouseUp()
        }
        switch parts[0] {
        case "fill":
            click("person.last")
            viewer.pdfView.debugType("Лавлейс")
            viewer.pdfView.endFieldEditing(commit: true)
            click("agree")
            click("plan", widget: 1)
            if let country = viewer.formFields.first(where: { $0.fullName == "country" }) { viewer.setValue("es", of: country) }
            if let when = viewer.formFields.first(where: { $0.fullName == "when" }) { viewer.setValue("07/03/2026", of: when) }
            click("notes")
            viewer.pdfView.debugType("Two lines of notes,\nthe second one here.")
            viewer.pdfView.endFieldEditing(commit: true)
        case "tab":
            // From the first field, Tab twice and type into where it lands.
            click("person.first")
            viewer.pdfView.endFieldEditing(commit: true)
            viewer.focusNextField()
            viewer.pdfView.endFieldEditing(commit: true)
            let landed = viewer.focusedWidget.flatMap { viewer.field(forWidget: $0) }?.field.fullName ?? "none"
            print("FORMS tab landed on \(landed)")
        case "editor":
            click(argument.isEmpty ? "person.first" : argument)
            viewer.pdfView.debugType("Typing here")
        case "date":
            if let hit = viewer.formFields.first(where: { $0.dateFormat != nil }).flatMap({ viewer.field(forWidget: $0.widgets[0].id) }) {
                viewer.pdfView.showDatePicker(for: hit)
            }
        case "build":
            viewer.isFormEditing = true
            drag(.text, (100, 700), (320, 722))
            viewer.updateSelectedField("Rename Field") { $0.name = "Full name" }
            drag(.checkbox, (100, 660), (100, 660))
            drag(.radio, (100, 620), (116, 636))
            drag(.radio, (150, 620), (166, 636))
            drag(.dropdown, (100, 570), (260, 592))
            viewer.updateSelectedField("Change Option") { $0.options = [.init(value: "Small"), .init(value: "Medium"), .init(value: "Large")] }
            drag(.date, (300, 570), (300, 570))
            drag(.signature, (100, 480), (320, 530))
            drag(.text, (100, 380), (420, 460))
        case "select":
            viewer.isFormEditing = true
            click(argument)
        case "move":
            // Drag the selected field 60 points right and 30 down, then widen it by its right handle.
            guard let hit = viewer.selectedField else { return print("FORMS nothing selected") }
            let rect = hit.widget.rect
            _ = viewer.mouseDown(at: PDFPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2), pageIndex: hit.pageIndex, clickCount: 1)
            viewer.mouseDragged(to: PDFPoint(x: rect.x + rect.width / 2 + 60, y: rect.y + rect.height / 2 - 30))
            viewer.mouseUp()
            if let moved = viewer.selectedField?.widget.rect {
                _ = viewer.mouseDown(at: PDFPoint(x: moved.x + moved.width, y: moved.y + moved.height / 2), pageIndex: hit.pageIndex, clickCount: 1)
                viewer.mouseDragged(to: PDFPoint(x: moved.x + moved.width + 50, y: moved.y + moved.height / 2))
                viewer.mouseUp()
            }
            print("FORMS moved from \(rect) to \(String(describing: viewer.selectedField?.widget.rect))")
        case "delete": viewer.deleteSelection()
        case "detect":
            viewer.isFormEditing = true
            viewer.detectFields()
            print("FORMS detect: \(viewer.detectionMessage ?? "nothing")")
            viewer.detectionMessage = nil
        case "done": viewer.isFormEditing = false
        case "reset": viewer.resetForm()
        case "flatten": viewer.flattenForm()
        case "undo":
            var steps = 0
            while document.undoManager?.canUndo == true, steps < 200 {
                document.undoManager?.undo()
                steps += 1
            }
        case "saved":
            let saved = document.currentData
            let reader = PDFDocument(data: saved)
            let widgets = reader?.page(at: 0)?.annotations.filter { $0.type == "Widget" } ?? []
            let values = widgets.map { "\($0.fieldName ?? "?")=\($0.widgetStringValue ?? "")\($0.widgetFieldType == .button ? ($0.buttonWidgetState == .onState ? "on" : "off") : "")" }
            print("FORMS saved: \(saved.count) bytes, keeps original=\(saved.prefix(document.contents.data.count) == document.contents.data), PDFKit reads \(values)")
        case "screen":
            // What PDFKit is showing for each field right now.
            let shown = (viewer.document?.page(at: 0)?.annotations ?? []).map { annotation in
                "\(annotation.fieldName ?? annotation.type ?? "?")=\(annotation.widgetStringValue ?? "")\(annotation.widgetFieldType == .button ? (annotation.buttonWidgetState == .onState ? "on" : "off") : "")"
            }
            print("FORMS screen: \(shown)")
        case "sign":
            // Click the signature field, then choose a signature as the popover would.
            click("sign")
            if let signature = SignatureMaker.signature(fromText: "Ada Lovelace", fontName: "SnellRoundhand") { viewer.place(signature) }
            let stamps = ((try? document.editor?.annotations(onPageAt: 0)) ?? []).filter { $0.kind == .stamp }
            let field = viewer.formFields.first { $0.fullName == "sign" }?.widgets.first?.rect
            print("FORMS sign: stamp at \(stamps.map(\.rect)) in field \(String(describing: field))")
        case "signPopover":
            click("sign")
        case "poke":
            if let page = viewer.document?.page(at: 0) { viewer.pdfView.annotationsChanged(on: page) }
        case "report": break
        default: print("FORMS unknown step \(step)")
        }
        report("after \(step)")
    }

    private static var didRunEdit = false

    /// Where flows put their results in automated runs, in place of asking.
    static var flowOutputFolder: URL? {
        UserDefaults.standard.string(forKey: "SnapshotFlowFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Changes text and pictures the way the mouse and keyboard would, and reports what the pages hold.
    private static func runEdit(_ step: String, _ viewer: ViewerModel) {
        guard let document = viewer.sheafDocument else { return }
        let parts = step.split(separator: ":").map(String.init)
        func argument(_ index: Int) -> String { parts.count > index ? parts[index] : "" }
        func number(_ index: Int) -> Double { Double(argument(index)) ?? 0 }
        let pageIndex = viewer.currentPageIndex
        func report(_ label: String) {
            guard let content = viewer.content(ofPage: pageIndex) else { return print("EDIT \(label): page cannot be read") }
            let blocks = content.blocks.prefix(8).map { "\($0.text.replacingOccurrences(of: "\n", with: "⏎").prefix(60))@\(Int($0.frame.x)),\(Int($0.frame.y))" + ($0.isEditable ? "" : "(locked)") }
            let images = content.images.map { image in
                "\(Int(image.placement.width.rounded()))x\(Int(image.placement.height.rounded()))@\(Int(image.frame.x.rounded())),\(Int(image.frame.y.rounded())) turned \((image.placement.rotation * 10).rounded() / 10)"
                    + (image.placement.isMirrored ? " mirrored" : "") + (image.opacity < 1 ? " opacity \(image.opacity)" : "")
                    + (image.shownPart.map { " mask \($0.x),\($0.y),\($0.width),\($0.height)" } ?? "") + (image.isEditable ? "" : "(locked)")
            }
            let shown = viewer.document?.page(at: pageIndex)?.string?.replacingOccurrences(of: "\n", with: "⏎").prefix(120) ?? ""
            print("EDIT \(label): \(content.blocks.count) blocks \(blocks), images \(images), marks \(viewer.redactionMarkCount), matches \(viewer.textMatches.count), selection \(String(describing: viewer.contentSelection)), moves \(viewer.stackingMoves.map(\.rawValue).sorted()), undo=\(document.undoManager?.canUndo ?? false), PDFKit shows “\(shown)”")
        }
        func block(containing text: String) -> TextBlock? {
            viewer.content(ofPage: pageIndex)?.blocks.first { $0.text.contains(text) }
        }
        /// A point on the page as displayed, as the mouse would report it.
        func pagePoint(_ x: Double, _ y: Double) -> PDFPoint {
            viewer.content(ofPage: pageIndex)?.geometry.pagePoint(PDFPoint(x: x, y: y)) ?? PDFPoint(x: x, y: y)
        }
        func click(_ x: Double, _ y: Double, count: Int = 1) {
            _ = viewer.contentMouseDown(at: pagePoint(x, y), pageIndex: pageIndex, clickCount: count)
            viewer.contentMouseUp()
            viewer.mouseUp()
        }
        func dragMouse(_ from: (Double, Double), _ to: (Double, Double), release: Bool = true, modifiers: NSEvent.ModifierFlags = []) {
            _ = viewer.contentMouseDown(at: pagePoint(from.0, from.1), pageIndex: pageIndex, clickCount: 1, modifiers: modifiers)
            let middle = pagePoint((from.0 + to.0) / 2, (from.1 + to.1) / 2), end = pagePoint(to.0, to.1)
            for point in [middle, end] {
                if viewer.contentDrag != nil || viewer.maskEdit != nil { viewer.contentMouseDragged(to: point, modifiers: modifiers) } else { viewer.mouseDragged(to: point) }
            }
            guard release else { return }
            viewer.contentMouseUp()
            viewer.mouseUp()
        }
        switch parts[0] {
        case "on": viewer.isContentEditing = true
        case "off": viewer.isContentEditing = false
        case "inspector": viewer.isInspectorVisible = true
        case "rotate": viewer.rotatePages([pageIndex], by: 90)
        case "tool": viewer.editTool = EditTool(rawValue: argument(1)) ?? .select
        case "select":
            guard let found = block(containing: argument(1)) else { return print("EDIT no block with \(argument(1))") }
            click(found.frame.x + 2, found.frame.y + found.frame.height / 2)
        case "open":
            // A double click on the block, which puts the cursor in it.
            guard let found = block(containing: argument(1)) else { return print("EDIT no block with \(argument(1))") }
            click(found.frame.x + 2, found.frame.y + found.frame.height / 2, count: 2)
            print("EDIT open: editable=\(found.isEditable) editing=\(viewer.pdfView.isEditingContent) selection=\(String(describing: viewer.contentSelection)) block=\(found.id) frame=\(found.frame)")
        case "zoom":
            switch argument(1) {
            case "page": viewer.zoomToFitPage()
            case "width": viewer.zoomToFit()
            case "in": viewer.zoomIn()
            default: viewer.setZoom(percent: Int(number(1)))
            }
            let checked = ViewerModel.zoomSteps.filter(viewer.isZoomed)
            print("EDIT zoom \(argument(1)): \(viewer.zoomPercent)% fitWidth=\(viewer.isFitToWindow) fitPage=\(viewer.isFitPage) checked=\(checked) view=\(Int(viewer.pdfView.bounds.width))x\(Int(viewer.pdfView.bounds.height))")
        case "titlebar":
            // Which view a click in the toolbar's empty space lands on, row by row from the
            // top of the window, and whether a double click there zooms the window.
            guard let window = viewer.pdfView.window, let frameView = window.contentView?.superview else { return }
            let x = number(1) > 0 ? number(1) : 420
            func dump(_ view: NSView, _ depth: Int) {
                guard depth < 7 else { return }
                print("EDIT toolbar \(String(repeating: " ", count: depth))\(String(describing: type(of: view)).prefix(60)) \(Int(view.frame.minX)),\(Int(view.frame.minY)) \(Int(view.frame.width))x\(Int(view.frame.height))")
                for subview in view.subviews { dump(subview, depth + 1) }
            }
            if let title = frameView.hitTest(CGPoint(x: x, y: window.frame.height - 15)) {
                var top: NSView = title
                while let parent = top.superview, !String(describing: type(of: top)).hasPrefix("NSToolbarTitleView") { top = parent }
                dump(top, 0)
            }
            // A double click in the title's row, put in the queue as a real one would be.
            let fromTop = number(2) > 0 ? number(2) : 15
            let point = CGPoint(x: x, y: window.frame.height - fromTop)
            let hit = frameView.hitTest(point).map { String(describing: type(of: $0)) } ?? "nothing"
            let before = window.frame
            for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("EDIT titlebar \(Int(fromTop)) pt from top on \(hit): frame \(before.size) to \(window.frame.size), zoomed=\(window.frame != before)")
                if window.frame != before { window.setFrame(before, display: true) }
            }
        case "views":
            for view in viewer.pdfView.subviews {
                print("EDIT view \(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) text=\((view as? NSTextView)?.string.prefix(20) ?? "")")
            }
            print("EDIT responder \(String(describing: viewer.pdfView.window?.firstResponder.map { type(of: $0) })) editing=\(viewer.pdfView.isEditingContent)")
        case "type":
            viewer.pdfView.debugType(argument(1).replacingOccurrences(of: "\\n", with: "\n"))
        case "commit": viewer.pdfView.endContentEditing(commit: true)
        case "swap":
            // Changes some words of a block through the editor, keeping the rest as typed.
            guard let found = block(containing: argument(1)) else { return print("EDIT no block with \(argument(1))") }
            click(found.frame.x + 2, found.frame.y + found.frame.height / 2, count: 2)
            viewer.pdfView.debugType(found.flowingText.replacingOccurrences(of: argument(1), with: argument(2)))
            viewer.pdfView.endContentEditing(commit: true)
        case "move":
            guard let frame = viewer.selectedBlock?.frame ?? viewer.selectedImage?.frame else { return print("EDIT nothing selected") }
            let from = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            dragMouse(from, (from.0 + number(1), from.1 + number(2)), release: argument(3) != "hold")
        case "resize":
            // Pulls the bottom right handle out along the picture's own sides.
            guard let placement = viewer.selectedImage?.placement else { return print("EDIT no picture selected") }
            let from = placement.point(atFractionX: 1, y: 0)
            let to = placement.point(atFractionX: 1 + number(1) / placement.width, y: -number(2) / placement.height)
            dragMouse((from.x, from.y), (to.x, to.y))
        case "turn":
            // Command and a drag of the top right handle, around the picture's center.
            guard let placement = viewer.selectedImage?.placement else { return print("EDIT no picture selected") }
            let from = placement.point(atFractionX: 1, y: 1)
            var turned = placement
            turned.rotation += number(1)
            let to = turned.point(atFractionX: 1, y: 1)
            dragMouse((from.x, from.y), (to.x, to.y), release: argument(2) != "hold", modifiers: argument(2) == "shift" ? [.command, .shift] : .command)
        case "pick":
            // Selects the picture with a number, as they are drawn.
            guard let image = viewer.content(ofPage: pageIndex)?.images.first(where: { $0.id == Int(number(1)) }) else { return print("EDIT no such picture") }
            viewer.contentSelection = .image(pageIndex: pageIndex, id: image.id)
        case "restack": if let move = StackingMove(rawValue: argument(1)) { viewer.restackSelection(move) }
        case "align": if let alignment = PageAlignment(rawValue: argument(1)) { viewer.alignSelection(alignment) }
        case "flip": viewer.flipSelectedPicture(horizontally: argument(1) != "v")
        case "opacity": viewer.setSelectedPictureOpacity(number(1))
        case "duplicate": viewer.duplicateContentSelection()
        case "cut": viewer.cutContentSelection()
        case "copy":
            viewer.copyContentSelection()
            let image = NSImage(pasteboard: .general)
            print("EDIT pasteboard picture \(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none"), text \(NSPasteboard.general.string(forType: .string)?.prefix(40) ?? "none")")
        case "link": viewer.addLinkToContentSelection()
        case "background": viewer.removeBackgroundOfSelectedPicture()
        case "mask":
            // Opens the mask and drags its handles so the given part shows, as fractions of the picture.
            viewer.beginMaskEditing()
            guard let edit = viewer.maskEdit else { return print("EDIT no mask to change") }
            print("EDIT mask open: picture \(edit.picture.map { "\($0.width)x\($0.height)" } ?? "none")")
            guard parts.count >= 5 else { return }
            func drag(_ from: (Double, Double), _ to: (Double, Double)) {
                let start = edit.whole.point(atFractionX: from.0, y: from.1), end = edit.whole.point(atFractionX: to.0, y: to.1)
                dragMouse((start.x, start.y), (end.x, end.y))
            }
            let part = viewer.maskEdit?.part ?? edit.part
            drag((part.x, part.y), (number(1), number(2)))
            drag((part.x + part.width, part.y + part.height), (number(1) + number(3), number(2) + number(4)))
            if argument(5) != "hold" { viewer.endMaskEditing(commit: true) }
        case "unmask": viewer.resetMask()
        case "menu":
            // What a right click on the selection offers.
            guard let frame = viewer.selectedBlock?.frame ?? viewer.selectedImage?.frame, let window = viewer.pdfView.window,
                  let at = viewer.viewPoint(PDFPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2), pageIndex: pageIndex),
                  let event = NSEvent.mouseEvent(with: .rightMouseDown, location: viewer.pdfView.convert(at, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = viewer.pdfView.menu(for: event)
            else { return print("EDIT no menu") }
            func titles(_ menu: NSMenu) -> [String] {
                menu.items.map { item in
                    if item.isSeparatorItem { return "|" }
                    let enabled = item.submenu != nil || (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
                    return item.title + (enabled ? "" : "(off)") + (item.submenu.map { "[" + titles($0).joined(separator: ", ") + "]" } ?? "")
                }
            }
            print("EDIT menu: \(titles(menu).joined(separator: ", "))")
        case "pointer":
            // Moves the pointer onto a handle of the selected thing and reports what it turns into.
            guard let geometry = viewer.selectionGeometry ?? viewer.contentSelectionGeometry, let page = viewer.document?.page(at: geometry.pageIndex),
                  geometry.handles.indices.contains(Int(number(1))), let window = viewer.pdfView.window
            else { return print("EDIT no handle") }
            let handle = geometry.handles[Int(number(1))]
            let place = viewer.pdfView.convert(viewer.pdfView.convert(handle.point.cgPoint, from: page), to: nil)
            let modifiers: NSEvent.ModifierFlags = argument(2) == "cmd" ? .command : []
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: place, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                viewer.pdfView.mouseMoved(with: event)
            }
            let expected = viewer.pdfView.handleCursor(at: viewer.pdfView.convert(place, from: nil), modifiers: modifiers)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let cursor = NSCursor.current
                print("EDIT pointer \(handle.handle): size \(cursor.image.size) hot \(cursor.hotSpot) arrow=\(cursor == NSCursor.arrow) expected=\(expected.map { $0 == cursor } ?? false) key=\(window.isKeyWindow)")
            }
        case "stretch":
            // Drags a side handle of the selected text: `stretch:right:-120`.
            guard let frame = viewer.selectedBlock?.frame else { return print("EDIT no text selected") }
            let x = argument(1) == "left" ? frame.x : frame.x + frame.width, y = frame.y + frame.height / 2
            dragMouse((x, y), (x + number(2), y))
        case "editorSide":
            // Drags a side of the editor that is open: `editorSide:right:80` in points of the view.
            viewer.pdfView.debugDragEditorSide(left: argument(1) == "left", by: number(2))
        case "nudge": viewer.nudgeContentSelection(dx: number(1), dy: number(2))
        case "delete": viewer.deleteContentSelection()
        case "size": viewer.restyleSelectedBlock("Change Text Size", TextRestyle(fontSize: number(1)))
        case "font": viewer.restyleSelectedBlock("Change Font", TextRestyle(fontName: argument(1)))
        case "color": viewer.restyleSelectedBlock("Change Color", TextRestyle(color: .red))
        case "newtext":
            viewer.editTool = .text
            click(number(1), number(2))
            viewer.pdfView.debugType(argument(3).replacingOccurrences(of: "\\n", with: "\n"))
            if argument(4) != "hold" { viewer.pdfView.endContentEditing(commit: true) }
        case "picture":
            if let data = try? Data(contentsOf: URL(fileURLWithPath: step.dropFirst("picture:".count).description)) { viewer.addPicture(data) } else { print("EDIT cannot read picture") }
        case "image":
            guard let image = viewer.content(ofPage: pageIndex)?.images.first else { return print("EDIT no picture on the page") }
            click(image.frame.x + image.frame.width / 2, image.frame.y + image.frame.height / 2)
        case "paste":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(argument(1), forType: .string)
            viewer.pasteContent()
        case "find":
            viewer.showReplace()
            viewer.replaceQuery = argument(1)
            viewer.replacement = argument(2)
        case "next": viewer.selectMatch(offset: 1)
        case "replace": viewer.replaceCurrentMatch()
        case "replaceAll": viewer.replaceAllMatches()
        case "closeFind": viewer.isReplaceVisible = false
        case "mark":
            if let pattern = RedactionPattern(rawValue: argument(1)) { viewer.markForRedaction(pattern) } else { viewer.markMatchesForRedaction() }
        case "redact":
            viewer.editTool = .redact
            dragMouse((number(1), number(2)), (number(3), number(4)))
            viewer.editTool = .select
        case "preview": viewer.previewsRedactions = true
        case "confirm": viewer.isApplyRedactionsConfirmationPresented = true
        case "apply":
            viewer.applyRedactions()
            print("EDIT apply: \(viewer.editMessage ?? "")")
            viewer.editMessage = nil
        case "ocr":
            Task {
                let pages = viewer.pagesWithoutText(among: Array(0..<viewer.pageCount))
                let count = await viewer.recognizeText(onPages: pages) { _ in true }
                print("EDIT ocr: \(pages.count) pages without text, recognized on \(count), PDFKit reads “\(viewer.document?.page(at: 0)?.string?.replacingOccurrences(of: "\n", with: "⏎").prefix(160) ?? "")”")
            }
        case "sheet": viewer.activeSheet = ToolSheet(rawValue: argument(1))
        case "compare":
            // This document against the file at a path.
            let url = URL(fileURLWithPath: String(step.dropFirst("compare:".count)))
            guard let data = try? Data(contentsOf: url) else { return print("EDIT cannot read \(url.path)") }
            ToolInbox.shared.compare(
                original: CompareSource(data: document.currentData, name: "Original.pdf", password: document.password),
                revised: CompareSource(data: data, name: url.lastPathComponent, password: nil)
            )
            // A window nobody can see is not drawn, and so cannot be captured.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for window in NSApp.windows where window.title == "Compare Documents" {
                    window.setFrame(NSRect(x: 40, y: 60, width: 1100, height: 700), display: true)
                    window.orderFrontRegardless()
                }
            }
        case "flow":
            // One of the saved flows, by position, on this document.
            let flows = FlowStore.shared.flows
            guard flows.indices.contains(Int(number(1))) else { return print("EDIT no such flow") }
            print("EDIT flow: running “\(flows[Int(number(1))].name)” of \(flows.map(\.name))")
            viewer.run(flows[Int(number(1))])
        case "flowBatch":
            // A saved flow on files, with results in the folder named by -SnapshotFlowFolder.
            let flows = FlowStore.shared.flows
            guard flows.indices.contains(Int(number(1))), let folder = flowOutputFolder else { return print("EDIT no such flow, or no folder") }
            let urls = step.split(separator: ":").dropFirst(2).joined(separator: ":").split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            let run = FlowRun()
            run.start(flows[Int(number(1))], on: urls)
            Task {
                while run.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                let made = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
                print("EDIT flowBatch: \(run.phase), folder holds \(made)")
            }
        case "compared":
            guard let model = CompareModel.current else { return print("EDIT no compare window") }
            let changes = model.changes.map { "\($0.kind.rawValue) p\(($0.pageA ?? -1) + 1)/p\(($0.pageB ?? -1) + 1) “\($0.textA)”→“\($0.textB)” frames \($0.framesA.count)/\($0.framesB.count)" }
            let marks = (0..<(model.revisedView.document?.pageCount ?? 0)).map { model.revisedView.document?.page(at: $0)?.annotations.count ?? 0 }
            print("EDIT compared: \(changes), selection \(String(describing: model.selection)), marks on revised pages \(marks), progress \(String(describing: model.progress)), error \(model.errorMessage ?? "none")")
            model.step(1)
            print("EDIT compared: after next, selection \(String(describing: model.selection)), original at page \(model.originalView.currentPage.flatMap { model.originalView.document?.index(for: $0) } ?? -1)")
        case "undo":
            var steps = 0
            while document.undoManager?.canUndo == true, steps < 200 {
                document.undoManager?.undo()
                steps += 1
            }
        case "undoOne": document.undoManager?.undo()
        case "redo": document.undoManager?.redo()
        case "saved":
            let saved = document.currentData
            let reader = PDFDocument(data: saved)
            let text = reader?.page(at: pageIndex)?.string?.replacingOccurrences(of: "\n", with: "⏎") ?? ""
            let needle = argument(1)
            let raw = needle.isEmpty ? false : saved.range(of: Data(needle.utf8)) != nil
            print("EDIT saved: \(saved.count) bytes, keeps original=\(saved.prefix(document.contents.data.count) == document.contents.data), PDFKit reads “\(text.prefix(200))”" + (needle.isEmpty ? "" : ", “\(needle)” in text=\(text.contains(needle)), in bytes=\(raw)"))
        case "report": break
        default: print("EDIT unknown step \(step)")
        }
        report("after \(step)")
    }

    private static var didOpenSettings = false
    private static var didRunAction = false

    /// Unlocks a locked document when a password was passed.
    static func unlock(_ document: SheafDocument) {
        guard let password = UserDefaults.standard.string(forKey: "SnapshotPassword"),
              document.pdf?.isLocked == true else { return }
        _ = document.unlock(with: password)
    }

    /// Puts a viewer into the state the flags ask for.
    static func configure(_ viewer: ViewerModel) {
        let defaults = UserDefaults.standard
        guard defaults.double(forKey: "SnapshotWindows") > 0 else { return }
        if let sidebar = defaults.string(forKey: "SnapshotSidebar") {
            if let mode = SidebarMode(rawValue: sidebar) {
                viewer.showSidebar(mode)
            } else {
                viewer.isSidebarVisible = false
            }
        }
        if let layout = defaults.string(forKey: "SnapshotLayout").flatMap(PageLayout.init(rawValue:)) {
            viewer.layout = layout
        }
        if let search = defaults.string(forKey: "SnapshotSearch") {
            viewer.searchText = search
        }
        viewers.append(viewer)
        let pages = defaults.string(forKey: "SnapshotPages")
        let markup = defaults.string(forKey: "SnapshotMarkup")
        let zoom = defaults.double(forKey: "SnapshotZoom")
        let page = defaults.integer(forKey: "SnapshotPage")
        let showsGoToPage = defaults.bool(forKey: "SnapshotGoToPage")
        let exportExtension = defaults.string(forKey: "SnapshotExport")
        // Actions open or replace documents, which configures viewers again, so run them once.
        let action = didRunAction ? nil : defaults.string(forKey: "SnapshotAction")
        didRunAction = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if page > 0 { viewer.goToPage(index: page - 1) }
            if zoom > 0 {
                viewer.pdfView.autoScales = false
                viewer.pdfView.scaleFactor = zoom
            }
            if showsGoToPage { viewer.isGoToPagePresented = true }
            if let markup, !didRunMarkup {
                didRunMarkup = true
                for step in markup.split(separator: ",") { runMarkup(String(step), viewer) }
            }
            if let forms = defaults.string(forKey: "SnapshotForms"), !didRunForms {
                didRunForms = true
                for (index, step) in forms.split(separator: ",").map(String.init).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(index)) { runForms(step, viewer) }
                }
            }
            if let edit = defaults.string(forKey: "SnapshotEdit"), !didRunEdit {
                didRunEdit = true
                for (index, step) in edit.split(separator: ",").map(String.init).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(index)) {
                        let start = Date()
                        runEdit(step, viewer)
                        print("EDIT took \(Int(Date().timeIntervalSince(start) * 1000)) ms: \(step.prefix(30))")
                    }
                }
            }
            if let pages, !didRunPages {
                didRunPages = true
                // One step per turn of the run loop, since page changes show a moment later.
                let steps = pages.split(separator: ",").map(String.init)
                for (index, step) in steps.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(index)) { runPages(step, viewer) }
                }
            }
            switch action {
            case "print": viewer.printDocument()
            case "exportPanel": viewer.export()
            case "duplicate": NSDocumentController.shared.documents.first?.duplicate(nil)
            case "saveAs":
                // The real Save As panel, to see the options Sheaf adds to it.
                NSDocumentController.shared.documents.first?.saveAs(nil)
            case let name? where name.hasPrefix("saveWith:"):
                // Saves under a new name the way the panel would, with options: `archival`, `screen`, `jpeg`, `password`.
                guard let document = NSDocumentController.shared.documents.first else { break }
                let chosen = Set(name.dropFirst("saveWith:".count).split(separator: "+").map(String.init))
                let model = SaveOptionsModel(showsFormat: false)
                model.makesArchival = chosen.contains("archival")
                model.optimizesPictures = chosen.contains("screen")
                model.usesJPEG = chosen.contains("jpeg")
                if chosen.contains("password") { (model.password, model.verification) = ("secret", "secret") }
                SavePanelOptions.debugAttach(model, to: document)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("saved-with-options.pdf")
                let before = viewer.sheafDocument?.currentData.count ?? 0
                document.save(to: url, ofType: document.fileType ?? "com.adobe.pdf", for: .saveAsOperation) { error in
                    MainActor.assumeIsolated {
                        let written = (try? Data(contentsOf: url)) ?? Data()
                        let read = PDFDocument(data: written)
                        let text = String(decoding: written.prefix(200_000), as: UTF8.self) + String(decoding: written.suffix(20_000), as: UTF8.self)
                        print("SAVEAS \(name): error=\(String(describing: error)) bytes \(before) to \(written.count), PDFKit pages=\(read?.pageCount ?? -1) locked=\(read?.isLocked ?? false) encrypted=\(read?.isEncrypted ?? false), pdfa=\(text.contains("pdfaid")), window encrypted=\(viewer.sheafDocument?.editor?.base.isEncrypted ?? false) password=\(viewer.sheafDocument?.password != nil) undo=\(viewer.sheafDocument?.undoManager?.canUndo ?? false) fileURL=\(document.fileURL?.lastPathComponent ?? "none")")
                    }
                }
            case "revert":
                if let document = NSDocumentController.shared.documents.first, let url = document.fileURL, let type = document.fileType {
                    do {
                        try document.revert(toContentsOf: url, ofType: type)
                        print("ACTION revert done")
                    } catch {
                        print("ACTION revert failed: \(error)")
                    }
                }
            default: break
            }
            if let exportExtension, let type = UTType(filenameExtension: exportExtension) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("export.\(exportExtension)")
                do {
                    try viewer.write(to: url, as: type)
                    let data = try Data(contentsOf: url)
                    print("EXPORT \(exportExtension) bytes=\(data.count) head=\(data.prefix(8).map { String(format: "%02x", $0) }.joined())")
                } catch {
                    print("EXPORT \(exportExtension) failed: \(error)")
                }
            }
        }
    }

    private static func capture() {
        for window in NSApp.windows {
            print("WINDOW \(type(of: window)) visible=\(window.isVisible) title=\(window.title) modal=\(NSApp.modalWindow === window) tabs=\(window.tabbedWindows?.count ?? 1) sheet=\(window.attachedSheet != nil)")
        }
        for document in NSDocumentController.shared.documents {
            print("DOCUMENT \(document.displayName ?? "?") edited=\(document.isDocumentEdited) unautosaved=\(document.hasUnautosavedChanges) undo=\(document.undoManager?.canUndo ?? false) grouping=\(document.undoManager?.groupingLevel ?? -1)")
        }
        if UserDefaults.standard.bool(forKey: "SnapshotFrames") {
            for window in NSApp.windows where window.isVisible && window.title.hasSuffix(".pdf") {
                print("FRAME window \(window.frame.size) content \(window.contentView?.frame ?? .zero) min \(window.contentMinSize) layoutRect \(window.contentLayoutRect)")
                func walk(_ view: NSView, _ depth: Int) {
                    let name = String(describing: type(of: view))
                    if depth < 16, view.frame.width > 150 {
                        print("FRAME \(String(repeating: " ", count: depth))\(name.prefix(60)) \(view.frame) fitting=\(view.fittingSize.width)")
                    }
                    for subview in view.subviews { walk(subview, depth + 1) }
                }
                if let content = window.contentView { walk(content, 0) }
            }
        }
        for window in NSApp.windows where window.isVisible {
            if UserDefaults.standard.bool(forKey: "SnapshotTree") {
                func walk(_ view: NSView, _ depth: Int) {
                    guard depth < 9 else { return }
                    print("TREE \(String(repeating: " ", count: depth))\(String(describing: type(of: view)).prefix(70)) \(view.frame) hidden=\(view.isHidden)")
                    for subview in view.subviews { walk(subview, depth + 1) }
                }
                print("TREE window \(window.title) frame \(window.frame) occlusion visible=\(window.occlusionState.contains(.visible))")
                if let content = window.contentView { walk(content, 0) }
            }
            // The window server only has a picture of windows that are really on screen.
            let onScreen = window.occlusionState.contains(.visible)
            guard let png = (onScreen ? windowServerCapture(of: window) : nil) ?? viewCapture(of: window) else { continue }
            print("SNAPSHOT \(window.title)\t\(png.base64EncodedString())")
        }
        if UserDefaults.standard.bool(forKey: "SnapshotMenus") {
            for menu in NSApp.mainMenu?.items ?? [] {
                let items = menu.submenu?.items.map { item in
                    item.isSeparatorItem ? "|" : item.title + (item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalent)]") + (item.isHidden ? " (hidden)" : "")
                }
                print("MENU \(menu.title): \((items ?? []).joined(separator: ", "))")
            }
        }
        fflush(stdout)
        if UserDefaults.standard.bool(forKey: "SnapshotClearsRecents") {
            NSDocumentController.shared.clearRecentDocuments(nil)
        }

        // Dismiss a modal alert and capture once more to show what is left behind.
        if let alert = NSApp.modalWindow {
            NSApp.stopModal()
            alert.orderOut(nil)
            let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
                MainActor.assumeIsolated { capture() }
            }
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        if UserDefaults.standard.bool(forKey: "SnapshotQuits") {
            // An open sheet would veto quitting.
            for viewer in viewers {
                viewer.activeSheet = nil
                viewer.isSignatureCreatorPresented = false
            }
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            // Documents that were never saved would ask what to do with them.
            for document in NSDocumentController.shared.documents where document.fileURL == nil {
                print("DOCUMENT untitled: \(document.displayName ?? "?")")
                document.close()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
        }
    }

    /// What the window server composites, including PDFKit's tiled page layers. An app may
    /// capture its own windows without screen-recording permission. The function is hidden
    /// from Swift in current SDKs, so it is looked up at run time.
    private static func windowServerCapture(of window: NSWindow) -> Data? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFraming: UInt32 = 1 << 0
        guard let image = createImage(.null, includingWindow, UInt32(window.windowNumber), ignoreFraming)?.takeRetainedValue(),
              image.width > 1
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Fallback: AppKit's own drawing of the view tree. Misses asynchronously drawn layers.
    private static func viewCapture(of window: NSWindow) -> Data? {
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
