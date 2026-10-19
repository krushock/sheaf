import AppKit
import CoreText
import SheafKit

/// The fonts a block of text is shown in while it is being changed: the document's own,
/// when the document carries it and macOS can read it, so that the text looks and wraps
/// exactly as on the page, and the closest installed font for the rest.
struct EditorFont {
    /// The font most of the text is in.
    let primary: NSFont
    /// For words the document's font cannot draw, when `primary` is the document's own.
    let fallback: NSFont?

    static func font(for block: TextBlock, size: CGFloat, editor: PDFEditor?) -> EditorFont {
        let installed = NSFont(name: block.installedFontName, size: size) ?? .systemFont(ofSize: size)
        guard let editor, let id = block.fontProgramID, let program = try? editor.fontProgram(id),
              let descriptor = CTFontManagerCreateFontDescriptorFromData(program as CFData)
        else { return EditorFont(primary: installed, fallback: nil) }
        let own = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        guard drawsLikeThePage(own, block) else { return EditorFont(primary: installed, fallback: nil) }
        return EditorFont(primary: own as NSFont, fallback: installed)
    }

    /// Whether the document's font draws every letter of a word. A word it cannot draw
    /// whole is set in the installed font whole, on the page as here.
    func covers(_ word: Substring) -> Bool {
        var characters = Array(word.utf16)
        guard !characters.isEmpty else { return true }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(primary as CTFont, &characters, &glyphs, characters.count) && !glyphs.contains(0)
    }

    /// Whether a font program, as macOS reads it, gives the block's letters the glyphs and
    /// widths the page has. A subset may number its glyphs its own way, and macOS may then
    /// draw wrong letters; the page's widths tell.
    private static func drawsLikeThePage(_ font: CTFont, _ block: TextBlock) -> Bool {
        // Single letters, not the gaps between words.
        var all: [PageGlyph] = []
        for line in block.lines {
            for glyph in line.glyphs where glyph.text != " " && glyph.fontSize > 0 && glyph.text.utf16.count == 1 { all.append(glyph) }
        }
        // Only the block's main font is the one loaded.
        let byFont: [String: [PageGlyph]] = Dictionary(grouping: all) { (glyph: PageGlyph) in glyph.fontName }
        let main: [PageGlyph] = byFont.values.max { $0.count < $1.count } ?? []
        let sample = main.prefix(80)
        guard !sample.isEmpty else { return false }
        var missing = 0
        var ratios: [Double] = []
        for glyph in sample {
            var character = Array(glyph.text.utf16)
            var found = CGGlyph(0)
            guard CTFontGetGlyphsForCharacters(font, &character, &found, 1), found != 0 else {
                missing += 1
                continue
            }
            var advance = CGSize.zero
            let sized = CTFontCreateCopyWithAttributes(font, glyph.fontSize, nil, nil)
            CTFontGetAdvancesForGlyphs(sized, .horizontal, &found, &advance, 1)
            if glyph.advance > 0 { ratios.append(advance.width / glyph.advance) }
        }
        guard missing * 10 <= sample.count, !ratios.isEmpty else { return false }
        let median = ratios.sorted()[ratios.count / 2]
        return abs(median - 1) < 0.03
    }
}

/// Keeps the editor's words in the font the page will show them in, as they are typed:
/// the document's own font for words it can draw, the installed font for the others.
final class WordFontKeeper: NSObject, NSTextStorageDelegate {
    let fonts: EditorFont

    init(fonts: EditorFont) {
        self.fonts = fonts
    }

    func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
        guard editedMask.contains(.editedCharacters), let fallback = fonts.fallback else { return }
        let text = storage.string
        // Words end at spaces and line breaks, as the engine sees them.
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex { $0 == " " || $0.isNewline } ?? text.endIndex
            if start < end {
                let word = text[start..<end]
                let font = fonts.covers(word) ? fonts.primary : fallback
                let span = NSRange(start..<end, in: text)
                if storage.attribute(.font, at: span.location, effectiveRange: nil) as? NSFont != font {
                    storage.addAttribute(.font, value: font, range: span)
                }
            }
            start = end < text.endIndex ? text.index(after: end) : end
        }
    }
}
