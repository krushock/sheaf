import CoreGraphics
import CoreText
import Foundation

/// Finds installed fonts that stand in for the fonts a PDF names, and measures them.
public enum FontMatcher {
    /// What is known about a font from the document, beyond its name.
    public struct Traits: Sendable, Equatable {
        public var isBold = false
        public var isItalic = false
        public var isSerif = false
        public var isFixedPitch = false

        public init(isBold: Bool = false, isItalic: Bool = false, isSerif: Bool = false, isFixedPitch: Bool = false) {
            self.isBold = isBold
            self.isItalic = isItalic
            self.isSerif = isSerif
            self.isFixedPitch = isFixedPitch
        }
    }

    /// The installed font that is the very font a PDF names, under its installed name,
    /// or `nil` when that font is not installed and only a look-alike could be offered.
    public static func sameInstalledFont(as pdfName: String) -> String? {
        let cleaned = pdfName.split(separator: "+").last.map(String.init) ?? pdfName
        // Windows-style names put the style after a comma: "Arial,Bold".
        let dashed = cleaned.replacingOccurrences(of: ",", with: "-").replacingOccurrences(of: " ", with: "")
        var candidates = [cleaned, dashed]
        if let alias = aliases[dashed.lowercased()] { candidates.append(alias) }
        for suffix in ["MT", "PSMT"] { candidates.append(dashed + suffix) }
        for candidate in candidates where isInstalled(candidate) { return canonicalName(candidate) }
        return nil
    }

    /// The PostScript name of the installed font to use for a font named in a PDF: the
    /// font itself when it is installed, otherwise one of the same kind and weight.
    public static func installedName(for pdfName: String, traits: Traits) -> String {
        if let same = sameInstalledFont(as: pdfName) { return same }
        let cleaned = pdfName.split(separator: "+").last.map(String.init) ?? pdfName
        let dashed = cleaned.replacingOccurrences(of: ",", with: "-").replacingOccurrences(of: " ", with: "")

        // The family, with the same weight and slant.
        let family = dashed.split(separator: "-").first.map(String.init) ?? dashed
        for name in [family, spaced(family)] {
            if let found = member(ofFamily: name, traits: traits) { return found }
        }
        // Nothing by that name: a font of the same kind.
        let fallback = traits.isFixedPitch ? "Menlo" : traits.isSerif ? "Times New Roman" : "Helvetica Neue"
        return member(ofFamily: fallback, traits: traits) ?? "Helvetica"
    }

    private static let aliases: [String: String] = [
        "arial": "ArialMT", "arial-bold": "Arial-BoldMT", "arial-italic": "Arial-ItalicMT", "arial-bolditalic": "Arial-BoldItalicMT",
        "timesnewroman": "TimesNewRomanPSMT", "timesnewroman-bold": "TimesNewRomanPS-BoldMT",
        "timesnewroman-italic": "TimesNewRomanPS-ItalicMT", "timesnewroman-bolditalic": "TimesNewRomanPS-BoldItalicMT",
        "couriernew": "CourierNewPSMT", "couriernew-bold": "CourierNewPS-BoldMT",
        "couriernew-italic": "CourierNewPS-ItalicMT", "couriernew-bolditalic": "CourierNewPS-BoldItalicMT",
        "times-roman": "Times-Roman", "symbol": "Symbol", "zapfdingbats": "ZapfDingbatsITC",
    ]

    /// "TimesNewRoman" as "Times New Roman".
    private static func spaced(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, let last = result.last, last.isLowercase { result.append(" ") }
            result.append(character)
        }
        return result
    }

    private static func canonicalName(_ name: String) -> String {
        CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String
    }

    /// Whether a font with this PostScript or full name is installed. Core Text hands
    /// back a stand-in for names it does not know, so the answer is checked against the name.
    /// The family an installed font belongs to, as font menus name it: "Times New Roman"
    /// for "TimesNewRomanPS-BoldMT".
    public static func familyName(of fontName: String) -> String {
        CTFontCopyFamilyName(CTFontCreateWithName(fontName as CFString, 12, nil)) as String
    }

    public static func isInstalled(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = normalized(name)
        return normalized(CTFontCopyPostScriptName(font) as String) == wanted || normalized(CTFontCopyFullName(font) as String) == wanted
    }

    /// The member of an installed font's family that is bold or not, italic or not, as
    /// asked. `nil` keeps that side as the font has it. The font itself when its family
    /// has no such member.
    public static func styled(_ fontName: String, bold: Bool?, italic: Bool?) -> String {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        let symbolic = CTFontGetSymbolicTraits(font)
        let traits = Traits(
            isBold: bold ?? symbolic.contains(.traitBold), isItalic: italic ?? symbolic.contains(.traitItalic),
            isFixedPitch: symbolic.contains(.traitMonoSpace)
        )
        return member(ofFamily: familyName(of: fontName), traits: traits) ?? fontName
    }

    private static func member(ofFamily family: String, traits: Traits) -> String? {
        var symbolic: CTFontSymbolicTraits = []
        if traits.isBold { symbolic.insert(.traitBold) }
        if traits.isItalic { symbolic.insert(.traitItalic) }
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: symbolic.rawValue],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        guard let match = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, Set([kCTFontFamilyNameAttribute as String]) as CFSet) else { return nil }
        let font = CTFontCreateWithFontDescriptor(match, 12, nil)
        guard (CTFontCopyFamilyName(font) as String).lowercased() == family.lowercased() else { return nil }
        return CTFontCopyPostScriptName(font) as String
    }

    /// How far a character moves the pen in a font, in thousandths of the font size.
    public static func advance(of character: Character, fontName: String) -> Double? {
        let font = CTFontCreateWithName(fontName as CFString, 1000, nil)
        let units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        return advance.width
    }

    /// How far above and below the baseline a font reaches, in thousandths of its size.
    public static func verticalMetrics(fontName: String) -> (ascent: Double, descent: Double) {
        let font = CTFontCreateWithName(fontName as CFString, 1000, nil)
        return (CTFontGetAscent(font), CTFontGetDescent(font))
    }

    /// Whether a font has a glyph for every character of some text.
    public static func covers(_ text: String, fontName: String) -> Bool {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
    }
}
