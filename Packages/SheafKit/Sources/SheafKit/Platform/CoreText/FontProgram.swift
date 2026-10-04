import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// Reads the font files of installed fonts, for putting a font inside a document.
public enum FontProgram {
    /// The profile that says what sRGB color numbers mean, for documents that must carry one.
    public static var sRGBProfile: Data? {
        CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?
    }

    private static let cache = Mutex<[String: [String: Data]?]>([:])

    /// The tables of an installed font that draws its glyphs the TrueType way, by table name.
    ///
    /// `nil` for fonts of other kinds, which cannot be put in a document this way:
    /// PostScript-flavored fonts, fonts that vary along an axis, and fonts of pictures.
    public static func trueTypeTables(fontName: String) -> [String: Data]? {
        if let known = cache.withLock({ $0[fontName] }) { return known }
        let tables = readTables(fontName: fontName)
        cache.withLock {
            if $0.count > 32 { $0.removeAll() }
            $0[fontName] = .some(tables)
        }
        return tables
    }

    private static func readTables(fontName: String) -> [String: Data]? {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        // Asking for a font that is not installed gives another one in its place.
        guard CTFontCopyPostScriptName(font) as String == fontName else { return nil }
        func table(_ name: String) -> Data? {
            let tag = name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return CTFontCopyTable(font, CTFontTableTag(tag), []) as Data?
        }
        guard table("fvar") == nil, table("CFF ") == nil, table("CFF2") == nil else { return nil }
        var tables: [String: Data] = [:]
        for name in ["head", "hhea", "maxp", "hmtx", "loca", "glyf"] {
            guard let data = table(name) else { return nil }
            tables[name] = data
        }
        // Instructions for fitting outlines to pixels. Glyphs call into these, so they come along.
        for name in ["cvt ", "fpgm", "prep", "OS/2", "post", "cmap", "name"] {
            if let data = table(name) { tables[name] = data }
        }
        return tables
    }
}
