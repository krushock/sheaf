import Foundation
import PDFKit
@testable import SheafKit
import Testing

/// A form made by PDFKit, so the engine is tested against a file it did not write.
enum FormFixture {
    static func make() throws -> Data {
        let document = try #require(PDFDocument(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 612, height: 792)])))
        let page = try #require(document.page(at: 0))
        func widget(_ rect: CGRect, _ name: String, _ type: PDFAnnotationWidgetSubtype) -> PDFAnnotation {
            let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
            annotation.widgetFieldType = type
            annotation.fieldName = name
            page.addAnnotation(annotation)
            return annotation
        }
        let name = widget(CGRect(x: 100, y: 700, width: 220, height: 22), "name", .text)
        name.widgetStringValue = "Old value"
        name.font = NSFont(name: "Helvetica", size: 12)
        let notes = widget(CGRect(x: 100, y: 600, width: 300, height: 80), "notes", .text)
        notes.isMultiline = true
        let agree = widget(CGRect(x: 100, y: 560, width: 16, height: 16), "agree", .button)
        agree.widgetControlType = .checkBoxControl
        agree.buttonWidgetStateString = "Yes"
        agree.buttonWidgetState = .offState
        for (index, color) in ["Red", "Blue"].enumerated() {
            let radio = widget(CGRect(x: 100 + Double(index) * 40, y: 520, width: 16, height: 16), "color", .button)
            radio.widgetControlType = .radioButtonControl
            radio.buttonWidgetStateString = color
            radio.buttonWidgetState = .offState
        }
        let size = widget(CGRect(x: 100, y: 470, width: 150, height: 22), "size", .choice)
        size.choices = ["Small", "Medium", "Large"]
        size.isListChoice = false
        return try #require(document.dataRepresentation())
    }
}

@Suite struct FormTests {
    private func field(_ name: String, in source: some ObjectSource) throws -> FormField {
        try #require(try source.formFields().first { $0.fullName == name }, "no field named \(name)")
    }

    private func owner(of widget: ObjectID, in editor: PDFEditor) throws -> ObjectID {
        let field = try editor.formField(forWidget: widget)
        return try #require(field).id
    }

    /// PDFKit's widget at a place on the first page.
    private func widget(at x: Double, _ y: Double, in reference: Reference) throws -> PDFAnnotation {
        let page = try #require(reference.document.page(at: 0))
        let found = page.annotations.first { $0.bounds.contains(CGPoint(x: x, y: y)) }
        return try #require(found, "no widget at \(x), \(y)")
    }

    /// The share of pixels in a rectangle of the first page that are not white.
    private func ink(in rect: PDFRectangle, of data: Data) throws -> Double {
        let pixels = try #require(Reference(data).pixels(ofPage: 0, fullSize: true))
        var marked = 0, total = 0
        for row in Int(792 - rect.y - rect.height)..<Int(792 - rect.y) {
            for column in Int(rect.x)..<Int(rect.x + rect.width) {
                let offset = (row * 612 + column) * 4
                total += 1
                if pixels[offset] < 200 || pixels[offset + 1] < 200 || pixels[offset + 2] < 200 { marked += 1 }
            }
        }
        return Double(marked) / Double(max(total, 1))
    }

    // MARK: Reading

    @Test func fieldsAreReadWithWhatTheyInherit() throws {
        let file = try PDFFile(data: TestPDF.form())
        #expect(file.hasForm)
        let fields = try file.formFields()
        #expect(fields.map(\.fullName) == ["person.first", "person.last", "agree", "plan", "country", "notes", "sign", "when", "send"])
        #expect(fields.map(\.kind) == [.text, .text, .checkbox, .radio, .dropdown, .text, .signature, .text, .button])

        let first = fields[0]
        #expect(first.name == "first" && first.label == "First name")
        #expect(first.value == "Ada" && first.defaultValue == "Ada" && first.maxLength == 20)
        #expect(first.fontSize == 11 && first.textColor == PDFColor(red: 0, green: 0, blue: 1))
        #expect(first.widgets.map(\.pageIndex) == [0])
        #expect(first.widgets[0].rect == PDFRectangle(x: 100, y: 700, width: 200, height: 20))
        #expect(fields[1].isRequired && fields[1].alignment == .right && fields[1].value.isEmpty)

        #expect(fields[2].value == "Off" && fields[2].widgets.map(\.onState) == ["On"] && !fields[2].widgets[0].isOn)
        #expect(fields[3].value == "basic" && fields[3].widgets.map(\.onState) == ["basic", "pro"])
        #expect(fields[3].widgets.map(\.isOn) == [true, false])
        #expect(fields[4].options == [.init(value: "pt", title: "Portugal"), .init(value: "es", title: "Spain"), .init(value: "Other")])
        #expect(fields[4].value == "pt" && fields[4].displayValue == "Portugal" && fields[4].fontSize == 10)
        #expect(fields[5].isMultiline && fields[5].fontSize == 0)
        #expect(!fields[6].isSigned && fields[6].isFillable)
        #expect(fields[7].dateFormat == "dd/mm/yyyy")
        #expect(!fields[8].isFillable)
        #expect(try !PDFFile(data: Fixture.text3Pages.data).hasForm)
    }

    @Test func datesAreWrittenTheWayTheFormAsks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        #expect(FormDate.string(from: date, format: "dd/mm/yyyy") == "07/03/2026")
        #expect(FormDate.string(from: date, format: "m/d/yy") == "3/7/26")
        #expect(FormDate.string(from: date, format: "d mmm yyyy") == "7 Mar 2026")
        #expect(FormDate.string(from: date, format: "mmmm d, yyyy") == "March 7, 2026")
        #expect(FormDate.formatter(for: "dd/mm/yyyy").date(from: "07/03/2026") == date)
    }

    // MARK: Filling

    @Test func textIsFilledInAndShown() throws {
        let data = TestPDF.form()
        var editor = PDFEditor(try PDFFile(data: data))
        let first = try field("person.first", in: editor), last = try field("person.last", in: editor)
        #expect(try ink(in: last.widgets[0].rect, of: data) == 0)
        try editor.setFieldValue(last.id, to: "Лавлейс")
        try editor.setFieldValue(first.id, to: "A name that is far too long for it")
        let saved = try editor.serialized()
        #expect(saved.prefix(data.count) == data)

        let file = try PDFFile(data: saved)
        #expect(try field("person.last", in: file).value == "Лавлейс")
        #expect(try field("person.first", in: file).value == "A name that is far t")
        // The XML copy of the form, which would now disagree, is gone.
        #expect(try file.acroForm()?.dictionary["XFA"] == nil)
        // PDFKit reads the same values, and the page shows them.
        let reference = try Reference(saved)
        #expect(try widget(at: 400, 710, in: reference).widgetStringValue == "Лавлейс")
        #expect(try widget(at: 200, 710, in: reference).widgetStringValue == "A name that is far t")
        #expect(try ink(in: last.widgets[0].rect, of: saved) > 0.03)
        // Right-aligned: the ink is in the right half of the field.
        let rect = last.widgets[0].rect
        #expect(try ink(in: PDFRectangle(x: rect.x, y: rect.y, width: rect.width / 2, height: rect.height), of: saved) == 0)

        // Emptying a field removes its value.
        var again = PDFEditor(file)
        try again.setFieldValue(last.id, to: "")
        let emptied = try again.serialized()
        #expect(try field("person.last", in: PDFFile(data: emptied)).value.isEmpty)
        #expect(try ink(in: rect, of: emptied) == 0)
    }

    @Test func severalLinesWrapInsideTheField() throws {
        var editor = PDFEditor(try PDFFile(data: TestPDF.form()))
        let notes = try field("notes", in: editor)
        try editor.setFieldValue(notes.id, to: "First line\nSecond line, which is long enough that it has to wrap onto another line of the field")
        let saved = try editor.serialized()
        let rect = notes.widgets[0].rect
        // Text at the top, and more than one line of it.
        #expect(try ink(in: PDFRectangle(x: rect.x, y: rect.y + rect.height - 16, width: rect.width, height: 16), of: saved) > 0.03)
        #expect(try ink(in: PDFRectangle(x: rect.x, y: rect.y + rect.height - 48, width: rect.width, height: 16), of: saved) > 0.02)
        #expect(try ink(in: PDFRectangle(x: rect.x, y: rect.y, width: rect.width, height: 12), of: saved) == 0)
        #expect(try field("notes", in: PDFFile(data: saved)).value.contains("\n"))
    }

    @Test func checkboxesAndRadioButtonsSwitch() throws {
        var editor = PDFEditor(try PDFFile(data: TestPDF.form()))
        let agree = try field("agree", in: editor), plan = try field("plan", in: editor)
        try editor.setButton(agree.widgets[0].id, on: true)
        try editor.setButton(plan.widgets[1].id, on: true)
        var saved = try editor.serialized()
        var file = try PDFFile(data: saved)
        #expect(try field("agree", in: file).value == "On")
        #expect(try field("plan", in: file).value == "pro")
        #expect(try field("plan", in: file).widgets.map(\.isOn) == [false, true])
        var reference = try Reference(saved)
        #expect(try widget(at: 107, 667, in: reference).buttonWidgetState == .onState)
        #expect(try widget(at: 107, 627, in: reference).buttonWidgetState == .offState)
        #expect(try widget(at: 147, 627, in: reference).buttonWidgetState == .onState)
        // The pictures the file came with are still the ones in use.
        #expect(try file.object(agree.widgets[0].id).dictionaryValue?["AP"] == (try editor.base.object(agree.widgets[0].id).dictionaryValue?["AP"]))
        #expect(try ink(in: agree.widgets[0].rect, of: saved) > 0.4)

        try editor.setButton(agree.widgets[0].id, on: false)
        try editor.setFieldValue(plan.id, to: "basic")
        saved = try editor.serialized()
        file = try PDFFile(data: saved)
        reference = try Reference(saved)
        #expect(try field("agree", in: file).value == "Off")
        #expect(try widget(at: 107, 667, in: reference).buttonWidgetState == .offState)
        #expect(try widget(at: 107, 627, in: reference).buttonWidgetState == .onState)
        #expect(throws: SheafError.self) { try editor.setFieldValue(plan.id, to: "enterprise") }
    }

    @Test func dropdownsTakeAnOptionByValueOrTitle() throws {
        var editor = PDFEditor(try PDFFile(data: TestPDF.form()))
        let country = try field("country", in: editor)
        try editor.setFieldValue(country.id, to: "Spain")
        #expect(try field("country", in: editor).value == "es")
        #expect(try field("country", in: editor).displayValue == "Spain")
        #expect(throws: SheafError.self) { try editor.setFieldValue(country.id, to: "France") }
        let saved = try editor.serialized()
        #expect(try widget(at: 150, 590, in: Reference(saved)).widgetStringValue == "es")
        #expect(try ink(in: country.widgets[0].rect, of: saved) > 0.02)
    }

    @Test func resettingBringsBackDefaults() throws {
        var editor = PDFEditor(try PDFFile(data: TestPDF.form()))
        try editor.setFieldValue(try field("person.first", in: editor).id, to: "Grace")
        try editor.setFieldValue(try field("person.last", in: editor).id, to: "Hopper")
        try editor.setButton(try field("agree", in: editor).widgets[0].id, on: true)
        try editor.setFieldValue(try field("country", in: editor).id, to: "es")
        try editor.resetForm()
        let file = try PDFFile(data: editor.serialized())
        #expect(try field("person.first", in: file).value == "Ada")
        #expect(try field("person.last", in: file).value.isEmpty)
        #expect(try field("agree", in: file).value == "Off")
        #expect(try field("country", in: file).value.isEmpty)
    }

    @Test func flatteningTurnsTheFormIntoPlainPages() throws {
        var editor = PDFEditor(try PDFFile(data: TestPDF.form()))
        try editor.setFieldValue(try field("person.last", in: editor).id, to: "Hopper")
        try editor.setFieldValue(try field("notes", in: editor).id, to: "Офис 12, fi ligatures\nsecond line")
        try editor.setButton(try field("agree", in: editor).widgets[0].id, on: true)
        let filled = try editor.serialized()
        let before = try Reference(filled)
        #expect(try editor.flattenForm() >= 4)
        let flat = try editor.serialized()
        let file = try PDFFile(data: flat)
        #expect(try file.formFields().isEmpty && !file.hasForm)
        #expect(try file.catalog()["AcroForm"] == nil)
        let after = try Reference(flat)
        #expect(after.document.page(at: 0)?.annotations.isEmpty == true)
        // What was in the fields is still on the page.
        let last = PDFRectangle(x: 320, y: 700, width: 200, height: 20), agree = PDFRectangle(x: 100, y: 660, width: 14, height: 14)
        #expect(try ink(in: last, of: flat) > 0.03)
        #expect(try ink(in: agree, of: flat) > 0.4)
        #expect(before.pageCount == after.pageCount)
        // The values are still text: they can be found and copied, in any script.
        let text = after.texts[0]
        #expect(text.contains("Hopper") && text.contains("Офис 12, fi ligatures") && text.contains("second line"))
        #expect(!before.texts[0].contains("Hopper"))
        #expect(after.document.findString("Офис", withOptions: []).count == 1)
    }

    @Test func fieldTextIsStoredAsTextInASmallFont() throws {
        var editor = PDFEditor(try PDFFile(data: TestPDF.form()))
        let last = try field("person.last", in: editor)
        try editor.setFieldValue(last.id, to: "Hopper")
        let widget = try editor.object(last.widgets[0].id).dictionaryValue ?? [:]
        let normal = try editor.resolve(try editor.value("AP", in: widget).dictionaryValue?["N"] ?? .null).streamValue
        let look = try #require(normal)
        let content = String(decoding: try editor.decodedData(of: look), as: UTF8.self)
        // Marked as the field's text, and drawn with text operators, which is what lets
        // Preview replace it with its own drawing instead of adding to it.
        #expect(content.contains("/Tx BMC") && content.contains("BT") && content.contains("Tj") && content.contains("EMC"))
        let fonts = try editor.value("Font", in: try editor.value("Resources", in: look.dictionary).dictionaryValue ?? [:]).dictionaryValue ?? [:]
        let font = try editor.resolve(fonts.values.first ?? .null).dictionaryValue ?? [:]
        #expect(font["Subtype"]?.nameValue == "Type3")
        // Five different letters in "Hopper".
        #expect(try editor.value("CharProcs", in: font).dictionaryValue?.count == 5)
        #expect(font["ToUnicode"] != nil)
    }

    // MARK: Building

    @Test func aFormCanBeBuiltFromNothing() throws {
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 612, height: 792)])))
        let name = try editor.addField(NewField(kind: .text, name: "Name", rect: PDFRectangle(x: 100, y: 700, width: 200, height: 22)), toPageAt: 0)
        let again = try editor.addField(NewField(kind: .text, name: "Name", rect: PDFRectangle(x: 320, y: 700, width: 200, height: 22)), toPageAt: 0)
        let agree = try editor.addField(NewField(kind: .checkbox, name: "Agree", rect: PDFRectangle(x: 100, y: 660, width: 16, height: 16)), toPageAt: 0)
        let red = try editor.addField(NewField(kind: .radio, name: "Color", rect: PDFRectangle(x: 100, y: 620, width: 16, height: 16)), toPageAt: 0)
        let blue = try editor.addField(NewField(kind: .radio, name: "Color", rect: PDFRectangle(x: 140, y: 620, width: 16, height: 16)), toPageAt: 0)
        var sizeField = NewField(kind: .dropdown, name: "Size", rect: PDFRectangle(x: 100, y: 580, width: 150, height: 22))
        sizeField.options = [.init(value: "S", title: "Small"), .init(value: "L", title: "Large")]
        let size = try editor.addField(sizeField, toPageAt: 0)
        var dateField = NewField(kind: .text, name: "Date", rect: PDFRectangle(x: 320, y: 580, width: 120, height: 22))
        dateField.dateFormat = FormDate.standardFormat
        let date = try editor.addField(dateField, toPageAt: 0)
        try editor.addField(NewField(kind: .signature, name: "Signature", rect: PDFRectangle(x: 100, y: 500, width: 200, height: 50)), toPageAt: 0)

        var fields = try editor.formFields()
        #expect(fields.map(\.fullName) == ["Name", "Name 2", "Agree", "Color", "Size", "Date", "Signature"])
        #expect(fields.map(\.kind) == [.text, .text, .checkbox, .radio, .dropdown, .text, .signature])
        #expect(fields[3].widgets.map(\.id) == [red, blue] && fields[3].widgets.map(\.onState) == ["Choice1", "Choice2"])
        #expect(fields[5].dateFormat == "mm/dd/yyyy")

        try editor.setFieldValue(try owner(of: name, in: editor), to: "Ada Lovelace")
        try editor.setButton(agree, on: true)
        try editor.setButton(blue, on: true)
        try editor.setFieldValue(try owner(of: size, in: editor), to: "Large")
        try editor.setFieldValue(try owner(of: date, in: editor), to: "03/07/2026")
        let saved = try editor.serialized()

        // PDFKit sees a form with the same fields and values.
        let reference = try Reference(saved)
        #expect(try widget(at: 200, 711, in: reference).widgetFieldType == .text)
        #expect(try widget(at: 200, 711, in: reference).widgetStringValue == "Ada Lovelace")
        #expect(try widget(at: 420, 711, in: reference).fieldName == "Name 2")
        #expect(try widget(at: 108, 668, in: reference).widgetFieldType == .button)
        #expect(try widget(at: 108, 668, in: reference).buttonWidgetState == .onState)
        #expect(try widget(at: 108, 628, in: reference).buttonWidgetState == .offState)
        #expect(try widget(at: 148, 628, in: reference).buttonWidgetState == .onState)
        #expect(try widget(at: 148, 628, in: reference).widgetControlType == .radioButtonControl)
        #expect(try widget(at: 150, 590, in: reference).widgetFieldType == .choice)
        // PDFKit answers with the option's value in some files and its title in others.
        #expect(["L", "Large"].contains(try widget(at: 150, 590, in: reference).widgetStringValue ?? ""))
        #expect(try widget(at: 200, 520, in: reference).widgetFieldType == .signature)
        // The check mark and the chosen radio button are drawn; the other button is only its ring.
        #expect(try ink(in: PDFRectangle(x: 103, y: 663, width: 10, height: 10), of: saved) > 0.15)
        #expect(try ink(in: PDFRectangle(x: 145, y: 625, width: 6, height: 6), of: saved) > 0.8)
        #expect(try ink(in: PDFRectangle(x: 105, y: 625, width: 6, height: 6), of: saved) == 0)

        fields = try PDFFile(data: saved).formFields()
        #expect(fields.map(\.value) == ["Ada Lovelace", "", "Yes", "Choice2", "L", "03/07/2026", ""])
        #expect(fields[5].dateValue != nil)
        _ = again
    }

    @Test func fieldsCanBeChangedMovedAndRemoved() throws {
        var editor = PDFEditor(try PDFFile(data: TestPDF.form()))
        var country = try field("country", in: editor)
        country.name = "nation"
        country.label = "Where you live"
        country.isRequired = true
        country.options = [.init(value: "es", title: "Spain"), .init(value: "fr", title: "France")]
        country.fontSize = 14
        country.backgroundColor = PDFColor(red: 0.6, green: 0.8, blue: 1)
        try editor.updateField(country)
        var changed = try field("nation", in: editor)
        #expect(changed.label == "Where you live" && changed.isRequired && changed.fontSize == 14)
        #expect(changed.options.map(\.value) == ["es", "fr"])
        // "pt" is no longer an option, so the field is empty.
        #expect(changed.value.isEmpty)
        #expect(changed.backgroundColor == PDFColor(red: 0.6, green: 0.8, blue: 1))

        var first = try field("person.first", in: editor)
        first.name = "given"
        first.maxLength = 2
        try editor.updateField(first)
        #expect(try field("person.given", in: editor).value == "Ad")

        let rect = PDFRectangle(x: 300, y: 300, width: 180, height: 30)
        try editor.setWidgetRect(changed.widgets[0].id, to: rect)
        changed = try field("nation", in: editor)
        #expect(changed.widgets[0].rect == rect)
        let saved = try editor.serialized()
        #expect(try widget(at: 390, 315, in: Reference(saved)).fieldName == "nation")
        // The blue background fills the new frame.
        #expect(try ink(in: rect, of: saved) > 0.9)

        // Removing one radio button leaves the group; removing a lone widget removes its field.
        let plan = try field("plan", in: editor)
        try editor.removeWidget(plan.widgets[0].id)
        #expect(try field("plan", in: editor).widgets.map(\.onState) == ["pro"])
        #expect(try field("plan", in: editor).value == "Off")
        try editor.removeWidget(changed.widgets[0].id)
        try editor.removeWidget(try field("person.given", in: editor).widgets[0].id)
        let names = try PDFFile(data: editor.serialized()).formFields().map(\.fullName)
        #expect(names == ["person.last", "agree", "plan", "notes", "sign", "when", "send"])
    }

    // MARK: Loosely written forms

    @Test func widgetsWithoutAFormAreReadAndRepaired() throws {
        let data = try FormFixture.make()
        var editor = PDFEditor(try PDFFile(data: data))
        #expect(try editor.acroForm() == nil)
        let fields = try editor.formFields()
        #expect(fields.map(\.fullName) == ["name", "notes", "agree", "color", "size"])
        #expect(fields.map(\.kind) == [.text, .text, .checkbox, .radio, .dropdown])
        #expect(fields[0].value == "Old value" && fields[0].fontSize == 12)
        #expect(fields[3].widgets.count == 2)
        #expect(fields[4].options.map(\.value) == ["Small", "Medium", "Large"])

        try editor.setFieldValue(fields[0].id, to: "New value")
        try editor.setButton(fields[2].widgets[0].id, on: true)
        try editor.setButton(fields[3].widgets[1].id, on: true)
        try editor.setFieldValue(fields[4].id, to: "Medium")
        let saved = try editor.serialized()

        // The fields are now listed in a form, and buttons have a picture for each state.
        let file = try PDFFile(data: saved)
        // The four fields that were filled in, with both radio buttons, are now listed in a form.
        #expect(try file.value("Fields", in: try file.acroForm()?.dictionary ?? [:]).arrayValue?.count == 5)
        let read = try file.formFields()
        let values = Dictionary(uniqueKeysWithValues: read.map { ($0.fullName, $0.value) })
        #expect(values == ["name": "New value", "notes": "", "agree": "Yes", "color": "Choice2", "size": "Medium"])
        #expect(read.first { $0.fullName == "color" }?.widgets.map(\.isOn) == [false, true])
        let reference = try Reference(saved)
        #expect(try widget(at: 200, 711, in: reference).widgetStringValue == "New value")
        #expect(try widget(at: 108, 568, in: reference).buttonWidgetState == .onState)
        #expect(try widget(at: 148, 528, in: reference).buttonWidgetState == .onState)
        #expect(try widget(at: 108, 528, in: reference).buttonWidgetState == .offState)
        #expect(saved.prefix(data.count) == data)
    }

    @Test func theFixtureFilesMatchTheHandBuiltForms() throws {
        // The files in Fixtures are for opening in the app. SHEAF_WRITE_FIXTURES=1 rewrites them.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for (fixture, data) in [(Fixture.form, TestPDF.form()), (.paperForm, TestPDF.paperForm())] {
            if ProcessInfo.processInfo.environment["SHEAF_WRITE_FIXTURES"] != nil {
                try data.write(to: folder.appendingPathComponent(fixture.rawValue + ".pdf"))
            }
            #expect(try Data(contentsOf: folder.appendingPathComponent(fixture.rawValue + ".pdf")) == data)
        }
        #expect(try Reference(TestPDF.paperForm()).texts[0].contains("Full name"))
    }

    @Test func aPrintedFormOffersItsBoxesAndLines() throws {
        let editor = PDFEditor(try PDFFile(data: TestPDF.paperForm()))
        let found = try editor.detectFieldCandidates(onPageAt: 0)
        #expect(found.map(\.kind) == [.text, .text, .checkbox, .checkbox, .text, .text])
        #expect(found[4].isMultiline && found[4].rect == PDFRectangle(x: 72, y: 400, width: 400, height: 95))
    }

    // MARK: Detection

    @Test func drawnBoxesAndRulesAreOfferedAsFields() throws {
        let content = """
        0.5 w
        100 700 200 20 re S
        1 g 100 650 200 20 re f 0 g 100 650 200 20 re S
        100 600 12 12 re S
        q 1 0 0 1 20 0 cm 100 600 12 12 re S Q
        100 560 m 300 560 l S
        320 558 180 0.6 re f
        0.2 g 100 500 200 30 re f
        100 400 300 90 re S
        50 380 m 60 390 l S
        20 20 572 752 re S
        400 700 m 500 700 l 500 720 l 400 720 l h S
        """
        var editor = PDFEditor(try PDFFile(data: MinimalPDF.data(pageBoxes: [PDFRectangle(x: 0, y: 0, width: 612, height: 792)])))
        let stream = editor.add(.stream(PDFStream(data: Data(content.utf8))))
        try editor.update(try editor.pageIDs()[0]) { $0["Contents"] = .reference(stream) }

        let found = try editor.detectFieldCandidates(onPageAt: 0)
        let summary = found.map { "\($0.kind.rawValue) \(Int($0.rect.x)),\(Int($0.rect.y)) \(Int($0.rect.width))x\(Int($0.rect.height))\($0.isMultiline ? " lines" : "")" }
        #expect(summary == [
            "text 100,700 200x20", "text 400,700 100x20",
            "text 100,650 200x20",
            "checkbox 100,600 12x12", "checkbox 120,600 12x12",
            "text 100,561 200x16", "text 320,559 180x16",
            "text 100,400 300x90 lines",
        ])

        // Places that already have a field are not offered again.
        for candidate in found.prefix(4) {
            try editor.addField(NewField(kind: candidate.kind, name: "Field", rect: candidate.rect), toPageAt: 0)
        }
        #expect(try editor.detectFieldCandidates(onPageAt: 0).count == found.count - 4)
        #expect(try PDFEditor(PDFFile(data: Fixture.text3Pages.data)).detectFieldCandidates(onPageAt: 0).isEmpty)
    }
}
