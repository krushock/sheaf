import Foundation

/// The smallest complete PDF files, written by hand. New documents start from one of these
/// and are then filled in through a `PDFEditor`.
enum MinimalPDF {
    /// A document with one empty page per box. No boxes gives a document with no pages yet.
    static func data(version: (major: Int, minor: Int) = (1, 7), pageBoxes: [PDFRectangle] = []) -> Data {
        // Every page shares one empty content stream, which sits after the pages.
        let content = ObjectID(pageBoxes.count + 3)
        var objects: [PDFObject] = [
            ["Type": .name("Catalog"), "Pages": .reference(ObjectID(2))],
            [
                "Type": .name("Pages"), "Count": .integer(pageBoxes.count),
                "Kids": .array(pageBoxes.indices.map { .reference(ObjectID($0 + 3)) }),
            ],
        ]
        for box in pageBoxes {
            objects.append([
                "Type": .name("Page"), "Parent": .reference(ObjectID(2)), "MediaBox": box.object, "Resources": [:],
                "Contents": .reference(content),
            ])
        }
        if !pageBoxes.isEmpty { objects.append(.stream(PDFStream(data: Data()))) }
        var output = Data("%PDF-\(version.major).\(version.minor)\n%".utf8)
        output.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [(id: ObjectID, offset: Int)] = []
        for (index, object) in objects.enumerated() {
            let id = ObjectID(index + 1)
            offsets.append((id, output.count))
            Serializer.append(indirect: object, id: id, to: &output)
        }
        let table = output.count
        CrossReferenceWriter.appendTable(entries: offsets, includeFreeHead: true, to: &output)
        output.append(contentsOf: "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n".utf8)
        return output
    }
}

extension PDFEditor {
    /// A document with no pages, to assemble one in.
    static func empty(version: (major: Int, minor: Int) = (1, 7)) -> PDFEditor {
        // The bytes above always parse.
        PDFEditor(try! PDFFile(data: MinimalPDF.data(version: version)))
    }
}
