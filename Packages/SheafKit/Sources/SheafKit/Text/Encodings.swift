import Foundation

/// The built-in ways simple fonts number their characters, and what glyph names mean.
enum Encodings {
    /// The base encodings, each as 256 entries of text, empty where a code is unused.
    static let standard: [String] = {
        var table = [String](repeating: "", count: 256)
        for code in 0x20...0x7E { table[code] = String(UnicodeScalar(UInt8(code))) }
        table[0x27] = "\u{2019}"
        table[0x60] = "\u{2018}"
        let high: [Int: String] = [
            0xA1: "¡", 0xA2: "¢", 0xA3: "£", 0xA4: "\u{2044}", 0xA5: "¥", 0xA6: "ƒ", 0xA7: "§", 0xA8: "¤", 0xA9: "'", 0xAA: "“",
            0xAB: "«", 0xAC: "‹", 0xAD: "›", 0xAE: "ﬁ", 0xAF: "ﬂ", 0xB1: "–", 0xB2: "†", 0xB3: "‡", 0xB4: "·", 0xB6: "¶",
            0xB7: "•", 0xB8: "‚", 0xB9: "„", 0xBA: "”", 0xBB: "»", 0xBC: "…", 0xBD: "‰", 0xBF: "¿", 0xC1: "`", 0xC2: "´",
            0xC3: "ˆ", 0xC4: "˜", 0xC5: "¯", 0xC6: "˘", 0xC7: "˙", 0xC8: "¨", 0xCA: "˚", 0xCB: "¸", 0xCD: "˝", 0xCE: "˛",
            0xCF: "ˇ", 0xD0: "—", 0xE1: "Æ", 0xE3: "ª", 0xE8: "Ł", 0xE9: "Ø", 0xEA: "Œ", 0xEB: "º", 0xF1: "æ", 0xF5: "ı",
            0xF8: "ł", 0xF9: "ø", 0xFA: "œ", 0xFB: "ß",
        ]
        for (code, text) in high { table[code] = text }
        return table
    }()

    static let winAnsi: [String] = {
        var table = [String](repeating: "", count: 256)
        for code in 0x20...0xFF {
            if let text = String(data: Data([UInt8(code)]), encoding: .windowsCP1252) { table[code] = text }
        }
        // Codes Windows leaves empty show a bullet in PDF; the two special spaces read as plain ones.
        for code in [0x7F, 0x81, 0x8D, 0x8F, 0x90, 0x9D] { table[code] = "•" }
        table[0xA0] = " "
        table[0xAD] = "-"
        return table
    }()

    static let macRoman: [String] = {
        var table = [String](repeating: "", count: 256)
        for code in 0x20...0xFF {
            if let text = String(data: Data([UInt8(code)]), encoding: .macOSRoman) { table[code] = text }
        }
        table[0xCA] = " "
        return table
    }()

    static func base(named name: PDFName?) -> [String]? {
        switch name {
        case "WinAnsiEncoding": winAnsi
        case "MacRomanEncoding": macRoman
        case "StandardEncoding": standard
        default: nil
        }
    }

    // MARK: Glyph names

    /// What a glyph name stands for, by the conventions fonts follow: the common names,
    /// `uni0041` and `u1F600` forms, ligatures joined with underscores, and variants after a period.
    static func text(forGlyphNamed name: String) -> String? {
        let base = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        guard !base.isEmpty else { return nil }
        if base.contains("_") {
            let parts = base.split(separator: "_").map { text(forGlyphNamed: String($0)) }
            return parts.contains(where: { $0 == nil }) ? nil : parts.compactMap(\.self).joined()
        }
        if let known = names[base] { return known }
        if base.hasPrefix("uni"), base.count >= 7, (base.count - 3) % 4 == 0 {
            var result = ""
            var rest = base.dropFirst(3)
            while rest.count >= 4 {
                guard let value = UInt32(rest.prefix(4), radix: 16), let scalar = UnicodeScalar(value) else { return nil }
                result.unicodeScalars.append(scalar)
                rest = rest.dropFirst(4)
            }
            return result
        }
        if base.hasPrefix("u"), (5...7).contains(base.count), let value = UInt32(base.dropFirst(), radix: 16), let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        // The old names for Cyrillic letters.
        if base.hasPrefix("afii"), let number = Int(base.dropFirst(4)) {
            let value: Int? = switch number {
            case 10017...10022: 0x0410 + number - 10017
            case 10023: 0x0401
            case 10024...10049: 0x0416 + number - 10024
            case 10065...10070: 0x0430 + number - 10065
            case 10071: 0x0451
            case 10072...10097: 0x0436 + number - 10072
            default: nil
            }
            return value.flatMap { UnicodeScalar($0) }.map(String.init)
        }
        return nil
    }

    private static let names: [String: String] = {
        var table: [String: String] = [:]
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".unicodeScalars { table[String(scalar)] = String(scalar) }
        let list = """
        space 0020 exclam 0021 quotedbl 0022 numbersign 0023 dollar 0024 percent 0025 ampersand 0026 quotesingle 0027
        parenleft 0028 parenright 0029 asterisk 002A plus 002B comma 002C hyphen 002D period 002E slash 002F
        zero 0030 one 0031 two 0032 three 0033 four 0034 five 0035 six 0036 seven 0037 eight 0038 nine 0039
        colon 003A semicolon 003B less 003C equal 003D greater 003E question 003F at 0040
        bracketleft 005B backslash 005C bracketright 005D asciicircum 005E underscore 005F grave 0060
        braceleft 007B bar 007C braceright 007D asciitilde 007E
        nbspace 0020 nonbreakingspace 0020 exclamdown 00A1 cent 00A2 sterling 00A3 currency 00A4 yen 00A5 brokenbar 00A6
        section 00A7 dieresis 00A8 copyright 00A9 ordfeminine 00AA guillemotleft 00AB logicalnot 00AC sfthyphen 002D
        softhyphen 002D registered 00AE macron 00AF degree 00B0 plusminus 00B1 twosuperior 00B2 threesuperior 00B3 acute 00B4
        mu 00B5 paragraph 00B6 periodcentered 00B7 cedilla 00B8 onesuperior 00B9 ordmasculine 00BA guillemotright 00BB
        onequarter 00BC onehalf 00BD threequarters 00BE questiondown 00BF
        Agrave 00C0 Aacute 00C1 Acircumflex 00C2 Atilde 00C3 Adieresis 00C4 Aring 00C5 AE 00C6 Ccedilla 00C7
        Egrave 00C8 Eacute 00C9 Ecircumflex 00CA Edieresis 00CB Igrave 00CC Iacute 00CD Icircumflex 00CE Idieresis 00CF
        Eth 00D0 Ntilde 00D1 Ograve 00D2 Oacute 00D3 Ocircumflex 00D4 Otilde 00D5 Odieresis 00D6 multiply 00D7
        Oslash 00D8 Ugrave 00D9 Uacute 00DA Ucircumflex 00DB Udieresis 00DC Yacute 00DD Thorn 00DE germandbls 00DF
        agrave 00E0 aacute 00E1 acircumflex 00E2 atilde 00E3 adieresis 00E4 aring 00E5 ae 00E6 ccedilla 00E7
        egrave 00E8 eacute 00E9 ecircumflex 00EA edieresis 00EB igrave 00EC iacute 00ED icircumflex 00EE idieresis 00EF
        eth 00F0 ntilde 00F1 ograve 00F2 oacute 00F3 ocircumflex 00F4 otilde 00F5 odieresis 00F6 divide 00F7
        oslash 00F8 ugrave 00F9 uacute 00FA ucircumflex 00FB udieresis 00FC yacute 00FD thorn 00FE ydieresis 00FF
        quoteleft 2018 quoteright 2019 quotedblleft 201C quotedblright 201D quotesinglbase 201A quotedblbase 201E
        endash 2013 emdash 2014 bullet 2022 ellipsis 2026 dagger 2020 daggerdbl 2021 perthousand 2030
        guilsinglleft 2039 guilsinglright 203A fraction 2044 Euro 20AC trademark 2122 minus 2212
        fi FB01 fl FB02 ff FB00 ffi FB03 ffl FB04 florin 0192 circumflex 02C6 tilde 02DC caron 02C7 breve 02D8
        dotaccent 02D9 ring 02DA ogonek 02DB hungarumlaut 02DD OE 0152 oe 0153 Scaron 0160 scaron 0161
        Ydieresis 0178 Zcaron 017D zcaron 017E Lslash 0141 lslash 0142 dotlessi 0131
        Aogonek 0104 aogonek 0105 Cacute 0106 cacute 0107 Ccaron 010C ccaron 010D Dcaron 010E dcaron 010F
        Dcroat 0110 dcroat 0111 Eogonek 0118 eogonek 0119 Ecaron 011A ecaron 011B Gbreve 011E gbreve 011F
        Idotaccent 0130 Lacute 0139 lacute 013A Lcaron 013D lcaron 013E Nacute 0143 nacute 0144 Ncaron 0147 ncaron 0148
        Ohungarumlaut 0150 ohungarumlaut 0151 Racute 0154 racute 0155 Rcaron 0158 rcaron 0159 Sacute 015A sacute 015B
        Scedilla 015E scedilla 015F Tcaron 0164 tcaron 0165 Uring 016E uring 016F Uhungarumlaut 0170 uhungarumlaut 0171
        Zacute 0179 zacute 017A Zdotaccent 017B zdotaccent 017C Abreve 0102 abreve 0103 Amacron 0100 amacron 0101
        Emacron 0112 emacron 0113 Edotaccent 0116 edotaccent 0117 Imacron 012A imacron 012B Iogonek 012E iogonek 012F
        Omacron 014C omacron 014D Umacron 016A umacron 016B Uogonek 0172 uogonek 0173 Scommaaccent 0218 scommaaccent 0219
        Tcommaaccent 021A tcommaaccent 021B Gcommaaccent 0122 gcommaaccent 0123 Kcommaaccent 0136 kcommaaccent 0137
        Lcommaaccent 013B lcommaaccent 013C Ncommaaccent 0145 ncommaaccent 0146 Rcommaaccent 0156 rcommaaccent 0157
        Delta 2206 Omega 2126 pi 03C0 summation 2211 product 220F radical 221A infinity 221E integral 222B
        approxequal 2248 notequal 2260 lessequal 2264 greaterequal 2265 lozenge 25CA partialdiff 2202
        arrowleft 2190 arrowup 2191 arrowright 2192 arrowdown 2193 apple F8FF
        """
        let parts = list.split(whereSeparator: \.isWhitespace)
        var index = 0
        while index + 1 < parts.count {
            if let value = UInt32(parts[index + 1], radix: 16), let scalar = UnicodeScalar(value) { table[String(parts[index])] = String(scalar) }
            index += 2
        }
        return table
    }()
}
