import Foundation

/// A page's text laid out as a grid of rows and columns.
public struct TextGrid: Sendable, Equatable {
    public var rows: [[String]]

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

extension PageContent {
    /// The page's text as a table: pieces of text on the same baseline are a row, and
    /// pieces that sit above one another are a column.
    ///
    /// A page that is a table comes out as that table. A page of running text comes out
    /// as one column with a row for each line.
    public var grid: TextGrid {
        struct Piece {
            var text: String
            var left: Double
            var right: Double
            var baseline: Double
            var size: Double
        }
        var pieces: [Piece] = []
        for block in blocks {
            for line in block.lines {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                pieces.append(Piece(text: text, left: line.frame.x, right: line.frame.x + line.frame.width, baseline: line.baseline, size: line.fontSize))
            }
        }
        guard !pieces.isEmpty else { return TextGrid(rows: []) }

        // Rows: pieces whose baselines are within a fraction of a line of each other.
        pieces.sort { $0.baseline > $1.baseline }
        var rows: [[Piece]] = []
        for piece in pieces {
            if let last = rows.last?.first, abs(last.baseline - piece.baseline) <= max(min(last.size, piece.size) * 0.35, 1) {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }

        // Columns: bands across the page that pieces fall into. A piece joins a band it
        // overlaps; a piece that bridges two bands, as a heading across a table does,
        // must not weld them together, so wide pieces are placed last and only take a place.
        var bands: [(left: Double, right: Double)] = []
        let widths = pieces.map { $0.right - $0.left }.sorted()
        let usual = widths[widths.count / 2]
        func overlap(_ piece: Piece, _ band: (left: Double, right: Double)) -> Double {
            min(piece.right, band.right) - max(piece.left, band.left)
        }
        for piece in pieces.sorted(by: { $0.right - $0.left < $1.right - $1.left }) where piece.right - piece.left <= max(usual * 4, 40) {
            let touching = bands.indices.filter { overlap(piece, bands[$0]) > 0 }
            if touching.count == 1 {
                let index = touching[0]
                bands[index] = (min(bands[index].left, piece.left), max(bands[index].right, piece.right))
            } else if touching.isEmpty {
                bands.append((piece.left, piece.right))
            }
        }
        bands.sort { $0.left < $1.left }
        // Growing bands can come to overlap one another; those are one column.
        var merged: [(left: Double, right: Double)] = []
        for band in bands {
            if let last = merged.last, band.left < last.right - 1 {
                merged[merged.count - 1].right = max(last.right, band.right)
            } else {
                merged.append(band)
            }
        }
        if merged.isEmpty { merged = [(0, geometry.displaySize.width)] }

        func column(of piece: Piece) -> Int {
            // The band it overlaps most, or the nearest one.
            var best = 0
            var bestScore = -Double.infinity
            for (index, band) in merged.enumerated() {
                let score = overlap(piece, band) > 0 ? overlap(piece, band) : -min(abs(piece.left - band.right), abs(band.left - piece.right))
                if score > bestScore {
                    best = index
                    bestScore = score
                }
            }
            return best
        }

        var grid: [[String]] = []
        for row in rows {
            var cells = [String](repeating: "", count: merged.count)
            for piece in row.sorted(by: { $0.left < $1.left }) {
                let index = column(of: piece)
                cells[index] = cells[index].isEmpty ? piece.text : cells[index] + " " + piece.text
            }
            grid.append(cells)
        }
        return TextGrid(rows: grid)
    }
}

extension PDFEditor {
    /// A cell's text as a number, when it is written as one: digits with an optional
    /// sign, thousands separators, decimal point, percent sign or brackets for negatives.
    static func number(from text: String) -> Double? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.count <= 24, cleaned.contains(where: \.isNumber) else { return nil }
        var sign = 1.0
        var scale = 1.0
        if cleaned.hasPrefix("("), cleaned.hasSuffix(")") {
            sign = -1
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        if cleaned.hasSuffix("%") {
            scale = 0.01
            cleaned.removeLast()
        }
        if cleaned.hasPrefix("−") || cleaned.hasPrefix("–") { cleaned = "-" + cleaned.dropFirst() }
        // Only plain digits, separators and a sign: dates, codes and phone numbers stay text.
        guard cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == "." || $0 == "-" || $0 == "+") }) else { return nil }
        let groups = cleaned.split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 1 {
            // Commas only between groups of three digits.
            guard groups.dropFirst().allSatisfy({ $0.prefix { $0 != "." }.count == 3 }), groups[0].count <= 4 else { return nil }
            cleaned = groups.joined()
        }
        guard cleaned.filter({ $0 == "." }).count <= 1, cleaned.dropFirst().allSatisfy({ $0 != "-" && $0 != "+" }), let value = Double(cleaned) else { return nil }
        // A long row of digits is an account or reference number, not a quantity.
        if cleaned.filter(\.isNumber).count > 15 { return nil }
        if cleaned.hasPrefix("0"), cleaned.count > 1, !cleaned.hasPrefix("0.") { return nil }
        return value * sign * scale
    }

    /// The document as an Excel workbook, a sheet for each page, with the page's text
    /// arranged in rows and columns as it is on the page. Cells that hold numbers are numbers.
    ///
    /// - Parameter progress: Called with the fraction done. Return `false` to stop.
    public func spreadsheet(progress: ((Double) -> Bool)? = nil) throws -> Data {
        let count = try pageCount()
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        func columnName(_ index: Int) -> String {
            var name = ""
            var number = index + 1
            while number > 0 {
                name = String(UnicodeScalar(UInt8(65 + (number - 1) % 26))) + name
                number = (number - 1) / 26
            }
            return name
        }
        var archive = ZipArchive()
        var sheets = "", sheetRelationships = "", overrides = ""
        for index in 0..<count {
            if let progress, !progress(Double(index) / Double(max(count, 1))) { throw CancellationError() }
            let grid = try pageContent(at: index).grid
            var rows = ""
            for (rowIndex, cells) in grid.rows.enumerated() {
                var row = ""
                for (columnIndex, text) in cells.enumerated() where !text.isEmpty {
                    let reference = "\(columnName(columnIndex))\(rowIndex + 1)"
                    if let number = Self.number(from: text) {
                        row += "<c r=\"\(reference)\"\(text.hasSuffix("%") ? " s=\"1\"" : "")><v>\(Serializer.format(number))</v></c>"
                    } else {
                        row += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscaped(text))</t></is></c>"
                    }
                }
                if !row.isEmpty { rows += "<row r=\"\(rowIndex + 1)\">\(row)</row>" }
            }
            // Wide enough for what the column holds, within reason.
            var columns = ""
            for column in 0..<grid.columnCount {
                let longest = grid.rows.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 8
                columns += "<col min=\"\(column + 1)\" max=\"\(column + 1)\" width=\"\(min(max(longest + 2, 8), 60))\" customWidth=\"1\"/>"
            }
            let number = index + 1
            archive.add("xl/worksheets/sheet\(number).xml", header + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
                + (columns.isEmpty ? "" : "<cols>\(columns)</cols>") + "<sheetData>\(rows)</sheetData></worksheet>")
            sheets += "<sheet name=\"Page \(number)\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            sheetRelationships += "<Relationship Id=\"rId\(number)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(number).xml\"/>"
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        if let progress, !progress(1) { throw CancellationError() }

        archive.add("[Content_Types].xml", header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(overrides)</Types>")
        archive.add("_rels/.rels", header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        archive.add("xl/workbook.xml", header + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + "<sheets>\(sheets)</sheets></workbook>")
        archive.add("xl/_rels/workbook.xml.rels", header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(sheetRelationships)"
            + "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>")
        // Two looks: plain, and percent.
        archive.add("xl/styles.xml", header + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<fonts count=\"1\"><font><sz val=\"12\"/><name val=\"Helvetica\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"10\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs>"
            + "</styleSheet>")
        return archive.data()
    }
}
