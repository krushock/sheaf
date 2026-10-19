# Sheaf — Native macOS PDF Editor (RevPDF alternative)

Goal: a fully native macOS PDF editor that matches RevPDF 5.0's feature set but looks and
behaves like Apple built it (Preview / Pages / Freeform level of polish). Offline, no
accounts, no telemetry. Mac-first; no cross-platform compromises.

## 1. What RevPDF has (reference: github.com/Pawandeep-prog/revpdf-release, revpdf.com)

RevPDF is a cross‑platform app (Android, iOS, Windows, macOS, Linux) with a custom dark UI
(left nav rail: Home / Recent / Tools / Starred; card grids; its own "Save" button, custom
theme switcher, "Update Check", "Buy me a coffee"). On macOS it already uses Apple's Vision
OCR. The feature inventory, grouped the way their Tools screen groups it:

| Area | RevPDF feature |
|---|---|
| Edit | WYSIWYG text editing with paragraph reflow + font matching, image edit/replace/reposition, paste image from clipboard, find & replace, undo/redo, selection modes (Entity / Block / Line), box select, grid |
| Annotate | highlight, underline, comments/notes, freehand drawing tools, shapes, links (URL + internal), bookmarks, stamps, e‑signature (draw / type / import, reusable) |
| Forms | fill & save fillable PDFs; form builder (text, checkbox, radio, dropdown) with field detection |
| Protect | permanent redaction (manual + auto‑redact), customizable redaction look, watermark (text/image), header & footer (page numbers, text), remove password, PDF/A‑2a export |
| Organize | merge, split (by range / extract / every N / split page vertically or horizontally), reorder, rotate, delete pages (drag & drop) |
| Convert | scan to PDF (mobile), images → PDF (JPG/PNG/HEIC/WebP/AVIF), PDF → images, PDF → Word, PDF → Excel, OCR "Make searchable" (embed text layer), compress (quality/size control) |
| Review | PDF Compare (two versions, diff view) |
| Automate | Flows (reusable multi‑step pipelines), Batch process (compress / watermark / OCR many files) |
| Workspace | Home with Quick Actions + Recent Files grid/list + Starred, tabbed viewer, continuous scroll, metadata editor, share & print, localization, themes, "Open With" |

## 2. Product decisions

- **Native first.** SwiftUI app with AppKit where SwiftUI falls short (PDFView host,
  NSToolbar details, text editing overlays). No custom chrome, no custom themes: system
  light/dark, accent color, SF Symbols, Liquid Glass toolbar and sidebar materials.
- **Document‑based.** `DocumentGroup` + `ReferenceFileDocument` (NSDocument under the hood):
  native window tabs, Open Recent, Versions/autosave, title‑bar rename, proxy icon, dirty
  dot, Revert, Duplicate. RevPDF's "Home" launcher becomes an optional **Welcome window**
  (like Pages/Xcode) with Recents + Tools; the real workflow is File ▸ Open and Finder.
- **Preview‑style layout.** Unified toolbar; left sidebar (Thumbnails / Table of Contents /
  Annotations / Search / Bookmarks) via `NavigationSplitView`; right **Inspector**
  (`.inspector`) with `Form` grouped sections for the selected object; markup toolbar row
  that slides in like Preview's.
- **Tools instead of a "Tools page".** Every RevPDF "tool" becomes a `Tools` menu item +
  a toolbar command + a Shortcuts action (App Intents). Multi‑file tools (Merge, Batch,
  Compare, Flows) get small sheet/window UIs with drop zones.
- **System integration a cross‑platform app cannot offer:** Finder Quick Actions
  (Compress / Merge / OCR / Images→PDF), Services menu, Share sheet, Continuity Camera
  (Import from iPhone), scanner import (ImageCaptureCore), Shortcuts, Print dialog.
- **In‑house engine.** No third‑party PDF library. Apple frameworks do the reading and
  drawing; our own Swift package (`SheafKit`) does everything that changes a file.
  Details in section 3. The only third‑party dependency in the whole app is Sparkle for
  updates, outside the engine.

## 3. Engine: SheafKit (in‑house, Swift)

Why in‑house: PDFKit can draw on top of pages but cannot change what is already there.
Third‑party editors (PDFium, MuPDF) regenerate whole content streams, have no notion of
words/lines/paragraphs, do no font matching, and bring a C/C++ binary. We want surgical
edits, a Pages‑grade edit model, CoreText font matching, and one Swift object graph.

**SheafKit parses and writes PDF itself.** The original idea was to read objects through
Core Graphics, but Core Graphics does not expose object numbers, and an incremental writer
cannot work without them. So the engine has its own parser, which also gives exact byte
offsets for verbatim saving.

What Apple provides (used, not rewritten):
- **PDFKit** — rendering, page cache, text selection & search, annotations, forms,
  outlines, printing. Used by the app for display, and by the tests as the yardstick.
- **CoreText** — font matching, glyph metrics and outlines for subsetting (Phase 6).
- **Vision** — OCR, document segmentation, table/rectangle detection.
- **ImageIO / Core Image** — image decoding and recompression.
- **Core Graphics PDF context** — generating brand‑new pages (blank, images → PDF).
- **zlib, CommonCrypto, CryptoKit** — Flate, AES, MD5/SHA.

What SheafKit implements. Items 1–9 are done (Phase 2); the rest are later phases.
1. **Syntax** — tolerant lexer/parser and a serializer for all object types (`Syntax/`).
2. **File** — `PDFFile`: header, classic cross‑reference tables, cross‑reference streams,
   hybrid files, `/Prev` chains, object streams, and repair by scanning when the table is
   missing or wrong (`File/`).
3. **Filters** — Flate, LZW, ASCII85, ASCIIHex, RunLength, PNG and TIFF predictors.
   Image filters (DCT, JPX, CCITT, JBIG2) pass through untouched (`Filters/`).
4. **Security** — the standard handler: RC4 40–128, AES‑128, AES‑256 (revisions 2–6),
   user and owner passwords, permissions; reading and creating (`Security/`).
5. **Editing** — `PDFEditor`: a value type holding changed objects over an immutable
   file, so snapshots for undo are cheap (`Editing/`).
6. **Pages** — rotate, crop, reorder, remove, insert blank, duplicate. The page tree is
   flattened on the first structural change, with inherited attributes pushed down.
7. **Merge** — pages imported from another document with their fonts, images and
   annotations; object renumbering; identical leaf streams stored once.
8. **Writers** — incremental (original bytes untouched, changes appended, classic table or
   cross‑reference stream to match the file) and full rewrite (only reachable objects,
   deterministic numbering, optional new encryption) (`Writing/`).
9. **Content streams** — operations with operands, inline images; untouched operations
   keep their original bytes (`Content/`). Metadata: the information dictionary.
10. **Text layout model** — runs → words → lines → paragraphs, caret math, reflow (Phase 6).
11. **Fonts** — embedded font programs, CoreText matching, TrueType subsetting (Phase 6,
    time‑boxed 1.5 weeks).
12. **Images** — replace, insert, recompress (Phases 4 and 6).
13. **Redaction** — remove glyphs/images/paths in a region, verified by re‑extraction (Phase 6).
14. **Generators** — images → PDF, OCR text layer, watermark, header/footer, PDF/A (Phases 4–7).
15. **Analysis** — text with geometry, tables (Phases 6–7).

Structure rule: `SheafKit` has no UI and no AppKit. System libraries are imported only
under `SheafKit/Platform/`; a test enforces it.

How it is tested:
- Unit tests for every layer, and hand‑built files for the layouts tools here cannot
  produce (object streams, cross‑reference streams, nested page trees).
- Everything the engine writes is opened by PDFKit and compared: page count, text, page
  boxes, annotations, and rendered pixels.
- `make corpus` runs the engine over every PDF that ships with macOS and Xcode (about
  1,900 files): read, edit, save both ways, protect with a password, compare pixels.
- Fuzz tests feed thousands of damaged files; errors are fine, crashes and hangs are not.

## 4. App architecture

```
Sheaf/
  App/                SwiftUI App, DocumentGroup, WelcomeWindow, Settings, Commands (menu bar)
  Document/           SheafDocument (ReferenceFileDocument over SheafKit.Document), undo, autosave
  Viewer/             PDFViewRepresentable (PDFKit), toolbar, sidebar (thumbs/TOC/annots/search/bookmarks)
  Editor/             EditOverlay (AppKit view over PDFView): selection, handles, caret, guides,
                      drag & drop, text field editor; talks only to SheafKit
  Markup/             Annotation tools, Inspector panels (Format / Document), signatures, stamps
  Pages/              Page organizer grid (drag reorder, rotate, delete, insert, extract)
  Tools/              Merge, Split, Compress, Watermark, HeaderFooter, Metadata, Password, OCR,
                      ImagesToPDF, PDFToImages, Redact, Compare, ToWord, ToExcel, PDFA
  Flows/              Flow model, Flow editor, Batch runner
  Intents/            App Intents for every tool (Shortcuts + Finder Quick Actions)
  Shared/             extensions, errors, progress reporting
Packages/
  SheafKit/           the engine (section 3) + Tests with fixture PDFs
```

- Swift 6, strict concurrency. Engine work runs in actors; progress sheet with Cancel.
- Min target **macOS 26**. Xcode is installed; the Makefile selects it when `xcode-select` does not.
- Sandboxed, hardened runtime, Developer ID + notarization, Sparkle updates.

## 5. Editing must feel like Pages

The bar for editing is Pages: click anything and change it, drag anything, no modes.
- **Click to edit.** Single click on any text run shows the blue selection box with
  handles; double click puts a caret in it. Typing inserts with the matched font. Reflow
  happens inside the paragraph box (a PDF has no document‑wide flow).
- **Drag everything.** Images, text boxes, shapes, signatures, stamps drag with yellow
  alignment guides and arrow‑key nudging. Pages drag in the sidebar. Finder files drop
  onto a page (image → placed, PDF → inserted pages) or the tab bar (open). Drag out
  exports the object.
- **Pages‑style inspector.** Format / Document segmented control. Format shows context
  tabs (Text, Image, Shape, Annotation). Document shows page size, metadata, security,
  headers/footers.
- **Paste and insert.** ⌘V places an image or text at the cursor; Insert menu for Image,
  Text Box, Shape, Signature, Stamp, Link, Page, Page Number, Date.
- **One Undo** across engine edits, annotations and page moves. **No Save button**,
  autosave via NSDocument. Markup tools are a toolbar toggle, not a separate screen.

## 6. Phases

### Phase 0 — Project skeleton (½ day) ✅ done 2026‑10‑03
Xcode project, bundle id, sandbox entitlements, document types (PDF editor role, images
importable), `SheafKit` package + test target with fixture PDFs, `git init`, CI script,
full default menu bar, empty document window, Welcome window shell.

### Phase 1 — Viewer that feels like Preview (1 week) ✅ done 2026‑10‑03
PDFKit viewer (continuous / single / two‑up, zoom, fit, page field, pinch), sidebar
(Thumbnails, TOC, Bookmarks, Annotations, Search + ⌘F bar), document lifecycle (open,
save, Save As, Duplicate, Revert, Export, Print, Share, tabs, Open Recent, password
prompt), Welcome window (Recents grid/list, search, Quick Actions), Settings window.

### Phase 2 — SheafKit foundation (1.5 weeks) ✅ done 2026‑10‑03
Object model over Core Graphics, incremental writer, content‑stream parser/serializer
with verbatim pass‑through, page operations (insert/delete/move/rotate/crop), merge
with object renumbering, metadata & security read/write. Round‑trip tests: open →
no‑op save → byte‑identical original + valid trailer; every fixture re‑opens in Preview.

### Phase 3 — Annotate & sign (1 week) ✅ done 2026‑10‑03
Markup toolbar (select, highlight/underline/strikethrough, note, text box, shapes,
freehand ink, stamp, link, signature), inspector for annotation properties, signature
store (draw / type / import / Continuity Camera), bookmarks, links, comment threads,
flatten, undo/redo.

### Phase 4 — Pages & file tools (1.5 weeks) ✅ done 2026‑10‑03
Page organizer grid, split (ranges / every N / extract / by bookmark / vertical‑
horizontal), merge sheet, images→PDF, PDF→images, watermark, header & footer, metadata
editor, password set/remove, compress (presets + custom, in‑place image recompression),
scan import (Continuity Camera, ImageCaptureCore, Vision perspective fix). Each tool
registered as an App Intent → Shortcuts + Finder Quick Actions.

### Phase 5 — Forms (3–4 days) ✅ done 2026‑10‑03
Fill (PDFKit widgets, tab order, flatten, reset). Build: text, checkbox, radio,
dropdown, date, signature fields; inspector; auto‑detect fields from drawn boxes.

### Phase 6 — Content editing (3–4 weeks, the core) ✅ done 2026‑10‑03
Text layout model, fonts (time‑boxed subsetter + CoreText matching), EditOverlay with
Pages behaviors (section 5), image move/resize/replace/paste/delete, find & replace,
redaction (manual + auto patterns + preview + apply), OCR text layer. Exit criteria:
edit a word in a typical Word‑exported PDF and an InDesign PDF with no visible
difference; redacted text absent from extraction; all saves open in Preview and Acrobat.

### Phase 7 — Review, convert, automate (1.5 weeks) ✅ done 2026‑10‑03
Compare (synced scroll, text diff + visual diff, change list, report export), PDF→Word
and PDF→Excel via in‑house OOXML writer (marked Beta), PDF/A‑2b export, Flows (saved
step pipelines, batch runner, exposed as Shortcuts actions and Quick Actions).

### Phase 8 — Polish & ship (1 week) ✅ done 2026‑10‑03, except what needs your accounts
String Catalogs (en, ru), VoiceOver, keyboard navigation, Help Book, TipKit onboarding,
performance pass on 500+ page / 200 MB files, signing, notarization, DMG, Sparkle.

### Phase 9 — Apple Intelligence ✅ done 2026‑10‑04
What Pages does with the models built into macOS, as far as it fits a PDF, plus what a
PDF reader calls for. Everything runs on the Mac; Sheaf sends documents nowhere.
Writing Tools on text being edited and on selected text, Image Playground for new
pictures, Super Resolution, Auto Crop and Remove Background for pictures on a page,
descriptions of pictures. For documents: a Summary panel (summary, key points, questions
answered with the pages they are from), suggested title, subject and keywords, and a
"Summarize PDF" action for Shortcuts.

### Phase 10 — What Acrobat has ✅ done 2026‑10‑15
Looked at Acrobat Pro's Edit PDF and its help index and added what Sheaf lacked and a PDF
editor is expected to have: paragraph formatting in the options panel (bold, italic,
alignment, line spacing, space before paragraphs), Bates numbering, page backgrounds,
Crop Pages, Remove Hidden Information (Acrobat's Sanitize), Read Out Loud, and export to
rich text, web pages and plain text. Left out for now: lists, underline, character spacing
and horizontal scaling (need new text drawing), layers, measuring, accessibility tagging,
and certificate signatures.

## 7. What we intentionally do differently from RevPDF
No custom nav rail, cards, themes, in‑app Save button or coffee button. Standard toolbar,
menus, ⌘S, Versions, system appearance. Scanner → Continuity Camera + real scanners.
Flows also become Shortcuts actions and Finder Quick Actions. Starred → Finder tags.

## 8. Decisions log
- 2026‑10‑03: minimum macOS 26 ✔; Developer ID + notarization + Sparkle ✔; name "Sheaf" ✔; editing UX must match Pages (section 5).
- 2026‑10‑03: engine is in‑house (`SheafKit`, section 3); no PDFium/MuPDF. Mac‑first;
  Windows is not planned. Apple frameworks used freely, confined to one platform folder
  for layering, not for portability.
- 2026‑10‑03, Phase 0 done. Bundle id `com.valeryburtsev.Sheaf`. Project generated by
  XcodeGen from `project.yml`. App target uses Swift 6 with MainActor default isolation.
  Debug builds are signed to run locally; Developer ID comes in Phase 8.
- Document IO lives only in `Sheaf/Document/SheafDocument.swift`.
- Images (JPEG, PNG, HEIC, TIFF, WebP, GIF, BMP, AVIF) open as a one‑page PDF at natural
  size. Layout options belong to the Images → PDF tool in Phase 4.
- Opening a corrupt file at launch shows the system alert and then no window, the same
  as Preview. A Dock click brings up the Welcome window.
- No app icon yet (Phase 8). The View menu is empty until the Phase 1 viewer adds its commands.
- 2026‑10‑03: minimum raised to **macOS 27** at the user's request, to use the URL‑based
  SwiftUI `Document` protocol. That protocol turned out to deadlock in macOS 27.0.1 on
  Duplicate and Revert: AppKit reads the document on the main thread, and SwiftUI then
  blocks that thread on a semaphore while waiting for main‑actor work, before any app code
  runs. Sheaf therefore uses `ReferenceFileDocument`, which passes the same tests. Retry
  the new protocol on later 27.x releases; the change is one file. Nothing in the code now
  requires macOS 27, so the minimum could return to 26 if wanted (untested there).
- 2026‑10‑03, Phase 1 done. Notes on scope:
  - The page indicator is the window subtitle ("Page 3 of 12") plus Go ▸ Go to Page…,
    as in Preview, rather than a text field in the toolbar.
  - The sidebar has Thumbnails, Table of Contents, Highlights and Notes, and search
    results. A separate Bookmarks list waits for Phase 3, where bookmarks are created and
    stored in the outline; until then there would be nothing to list.
  - Welcome has New Document and Open. The tool quick actions (merge, compress, split,
    images) are added in Phase 4 together with the tools themselves.
  - Export writes a PDF copy, or the current page as PNG, JPEG, TIFF or HEIC at 144 dpi.
    Ranges, resolution and other options belong to the PDF → Images tool in Phase 4.
  - Settings has General and Viewing. Markup and Tools tabs arrive with those features.
  - Background work (thumbnails, annotation list) runs in `DocumentWorker`, an actor
    with its own `PDFDocument` parsed from the same bytes, because PDFKit objects are not
    safe to share across threads. Once edits exist it must be refreshed after each change.
  - PDFKit quirk found while making fixtures: it saves a new outline only for documents
    it assembled itself, not for one loaded from a file. Bookmarks in Phase 3 must be
    written by SheafKit, not by PDFKit.
- 2026‑10‑03: minimum back to **macOS 26** at the user's request, since nothing needs 27.
  Built and tested on macOS 27 only; behavior on 26 is unverified.
- 2026‑10‑03, Phase 2 done. 103 tests; corpus of 1,929 system PDFs with 0 problems.
  Things later phases must know:
  - **Appending never removes anything.** A deleted page's content stays in the file
    until a full rewrite. The UI needs an explicit "remove deleted content" path, and
    redaction (Phase 6) must always use the full rewrite.
  - **Keep the header version.** Apple's renderer draws transparency differently in files
    that claim to be older than PDF 1.4, so the writer only raises the version when new
    encryption requires it.
  - Removing pages also removes the bookmarks and links that pointed at them (Phase 4).
  - Form fields from a merged document keep their look but are not fillable. Form merging
    belongs with Phase 5. (Bookmarks do come along since Phase 4.)
  - Setting metadata also updates the document's XMP packet when it has one (Phase 4).
  - Rewritten files use a classic table unless asked to pack objects, which Reduce File
    Size does (Phase 4).
  - `PDFFile` is not thread‑safe and `PDFEditor` is not `Sendable`. The app must keep
    them on one actor.
  - Core Graphics writes 40‑bit RC4 files with a variant of the owner‑key derivation; the
    reader accepts both variants.
  - Core Graphics cannot create AES‑256 files, PDFKit writes RC4‑128. Sheaf's default for
    new passwords is AES‑256, which both open.
  - Speed on a generated 3,000‑page file: open 3 ms, reorder and save 0.2 s, rewrite 0.1 s.
- 2026‑10‑03, Phase 3 done. 122 engine tests; corpus still at 0 problems, now including
  annotate, bookmark and flatten on every file. How it is built, for later phases:
  - **The engine owns annotations.** `SheafKit/Annotations` has one `Annotation` type for
    all kinds, builds each one's appearance stream itself, and reads, adds, updates,
    removes and flattens. PDFKit only displays.
  - **`SheafDocument.apply`** is the one way to change a document. It edits a copy of the
    `PDFEditor`, registers undo with the previous copy, updates PDFKit, and refreshes the
    bytes to save. Phases 4 to 6 should go through it, setting `reloadsDisplay` when page
    content or order changes.
  - **Saving.** SwiftUI takes the save snapshot on a background thread, sometimes while the
    main thread waits. So the bytes to append are recomputed on the main thread after
    every edit (`PDFEditor.appendedBytes`, cost proportional to the changes) and kept
    behind a lock. Never hop to the main thread in `snapshot`.
  - **Display.** Changed and new annotations are shown by `SheafAnnotation`, which draws a
    one‑page PDF of the appearance, so the screen matches the saved file. Stamps and
    signatures are drawn from what the document stores (`storedAppearancePreview`).
    Highlights, underlines and strikethroughs are left to PDFKit's own drawing: PDFKit
    draws annotations on a layer above the page where nothing else can blend with the
    text, and it draws these kinds itself in any saved file anyway, a pixel or two tighter
    than the stored appearance.
  - **Interaction.** `SheafPDFView` handles the mouse and keyboard and passes page
    coordinates to `ViewerModel`, whose `mouseDown/Dragged/Up` hold all the logic. The
    selection frame is a transparent view over the PDF view, not drawn by PDFKit, because
    PDFKit may draw pages off the main thread.
  - **Text in text boxes and stamps is drawn as outlines**, so it looks right in every
    viewer and script without embedding a font, but cannot be selected or searched. The
    words are kept in the annotation's contents. Switch to embedded subset fonts when the
    subsetter exists (Phase 6).
  - A SwiftUI row of menu buttons reports a far larger minimum width than it draws. Inside
    a split view that pushes the sidebar and inspector off the window, so the markup bar
    is an overlay on a fixed‑height strip.
  - Not done: pen pressure (strokes have one width), copy and paste of annotations.
- 2026‑10‑03, Phase 4 done. 164 engine tests; the corpus run gained a fourth pass that
  compresses, splits, merges and stamps every file, at 0 problems. What needs a person to
  check is listed in [VERIFY.md](VERIFY.md). How it is built, for later phases:
  - **No Core Graphics in generation any more.** New documents, pictures as pages and
    merged documents are all assembled with `PDFEditor` on top of `MinimalPDF`. JPEG
    files go into a PDF as they are; HEIC, AVIF and WebP become JPEG at 90%; PNG and TIFF
    are stored exactly. A picture's ICC profile is kept when it is not sRGB.
  - **Drawing on pages** (`Content/PageOverlay.swift`): watermark and header/footer are
    new content streams fenced off from the page's own with `q … Q`, placed through
    `PageGeometry.fromDisplay` so they stand upright on turned pages. A watermark is one
    form object shared by all pages. Both are tagged as pagination artifacts, which is
    what would let a later "Remove Watermark" find them. Text is outlines, as in Phase 3;
    revisit with the font subsetter.
  - **Removing pages cleans up after itself.** `arrangePages` drops links and bookmarks
    that led to removed pages, so a rewrite really leaves those pages out.
  - **Extracting and merging copy pages into a fresh document** rather than deleting from
    a copy. Bookmarks come along renumbered. Left behind: the reading‑order tags
    (accessibility structure) and the form that fields belong to. Carrying tags across
    is worth doing with Phase 5 or 8.
  - **Compression** (`Editing/Compression.swift`): pictures are found by walking page
    content, nested forms and annotation appearances, with the size each is shown at.
    Only plain gray and RGB pictures (device, calibrated or ICC with 1 or 3 channels),
    8 bits, no color‑key mask, over 16 KB are touched. Photographs become JPEG;
    pictures with few colors stay exact. A result is used only if it is at least 10%
    smaller. Everything else: weakly compressed streams are deflated, thumbnails and
    `PieceInfo` dropped, identical streams merged, objects packed into object streams.
    Lossless compression of the 89 MB corpus gives 69 MB with every first page
    pixel‑identical.
  - **Packed files keep an old header version.** Raising a pre‑1.4 file to 1.5 changes how
    Apple's renderer draws it, so object streams are written under the version the file
    came with. Every reader goes by structure; a strict validator would complain.
  - **In a protected, packed file the catalog stays outside the object streams.** PDFKit
    reads the catalog before the password is known and refuses the file otherwise.
  - **Replacing the whole document** (`SheafDocument.replaceContents`): reduce, set
    password and remove password write the document out afresh and make those bytes the
    new base, as one undo step that also restores the previous password. What gets saved
    is `editor.base.data` plus appended changes, no longer the bytes as opened.
  - **Pages are identified by their object**, not their position: thumbnails, the organizer
    selection and its animated reordering all key on `ViewerModel.pageIDs`.
  - **The organizer is an `NSCollectionView`**, for rubber‑band selection, multi‑item drag
    with a moving gap, and file promises to the Finder. The pages view is taken out of
    the window while it shows, so code must use `ViewerModel.window`, not `pdfView.window`.
  - **New untitled documents from bytes** go through
    `NSDocumentController.duplicateDocument(withContentsOf:copying:displayName:)`. The
    window is titled "Untitled (Merged)", which is the system's form for an unsaved
    document with a suggested name.
  - **Tools are plain functions** in `Tools/Toolbox.swift`, used by the sheets, the tool
    windows, the 11 Shortcuts actions and the Services menu. Shortcuts actions read their
    parameters on the main actor and do the work in a detached task.
  - **Scanning** uses Image Capture's own views (`IKDeviceBrowserView`,
    `IKScannerDeviceView`), the ones Preview shows. Photos arriving from an iPhone are
    straightened with Vision (`DocumentStraightener`) when a sheet of paper is found.
  - Finder integration is through Services entries and Shortcuts actions. A Finder Sync
    or Action extension target was not added; Shortcuts actions can be turned into Quick
    Actions by the user.
  - A protected PDF that is inserted, dropped in or merged asks for its password
    (`PasswordRequest`); Skip leaves that document out. The merge window shows an Enter
    Password button on the row, and the Merge PDFs action takes one password that is tried
    on every protected file. The result is not protected.
  - Not done: crop tool UI (the engine has `setCropBox`), removing a watermark added
    earlier, Bates numbering.
- 2026‑10‑03, Phase 5 done. 179 engine tests; the corpus pass now also builds a form on
  every file, fills it, has PDFKit read it back and flattens it, at 0 problems. How it is
  built, for later phases:
  - **The engine owns forms** (`SheafKit/Forms`): `formFields()` reads fields with what
    they inherit; `setFieldValue`, `setButton`, `resetForm`, `flattenForm` fill;
    `addField`, `updateField`, `setWidgetRect`, `removeWidget` build;
    `detectFieldCandidates` finds drawn boxes and rules. A field's pictures are drawn by
    `FieldAppearance`.
  - **Field text is real text in a font made of glyph outlines** (`Content/GlyphFont.swift`,
    a Type 3 font with a ToUnicode map, built per appearance from CoreText's shaping). No
    font files are read or embedded, any script works, and the text can be searched and
    copied after flattening. It has to be real text: PDFKit (Preview, Safari) draws a
    field's value itself on top of the stored picture unless the picture's text is in
    text operators, which it then leaves out. Outlined text was drawn twice there.
    This font could replace outlines in text boxes, stamps, watermarks and headers too.
  - **Loosely written forms are accepted and repaired.** Apps built on PDFKit write
    widgets with no form dictionary, text styles as names, and buttons with one picture
    for both states. Such widgets are read as fields, fields with the same name are
    treated as one, and the first change lists them in a proper form and gives buttons a
    picture per state. An XFA copy of a form is removed when a field is filled in.
  - **Changed annotations are shown by PDFKit itself**, read from a one-page document the
    engine makes for each (`annotationDocument(for:onPageAt:)`). The earlier way, a
    `PDFAnnotation` subclass that draws, turned out to be drawn by PDFKit at one pixel
    per point and scaled, so everything from Phase 3 was soft when zoomed in. That
    subclass is now only used for links and as the stand-in while something is dragged,
    which is still soft for the length of the drag.
  - **PDFKit keeps one value per field name for the whole document** and gives it to any
    widget added to a page, so a remade widget is told its state again after it is added.
    PDFKit also tints fields only until a page's annotations are refreshed; the app
    refreshes each page with fields once and draws one tint of its own.
  - **Filling is the app's, not PDFKit's.** Clicks on fields never reach PDFKit:
    `ViewerModel.activate` opens a text editor over the field, a menu for a dropdown, a
    calendar for a date field, the saved signatures for a signature field, or switches a
    button. Tab order is the order of widgets on each page.
  - **Building** uses the same selection, drag and inspector code as annotations: a field
    is selected by its widget, and moving or resizing goes to `setWidgetRect`.
  - A signature field is "signed" by placing a signature stamp inside it. That is a
    picture of a signature, not a digital signature; certificates are not in the plan.
  - Not done: calculated fields and other scripts in forms (they are kept, not run),
    list boxes that take several choices, per-button values for radio buttons, tab order
    editing, detection of table grids drawn as separate lines, fields on rotated pages
    being drawn upright.
- 2026‑10‑03, Phase 6 done. 210 engine tests, fuzz clean. New corpus passes at 0 problems: text is read on 558 pages that have any (256 exactly as PDFKit reads them, 213 within 5%, the rest mostly CJK fonts with predefined encodings), a word is typed into 248 files and a line redacted in 167, each checked through PDFKit. How it is built, for later phases:
  - **Pages are read by the engine's own interpreter** (`SheafKit/Text`):
    `interpret(pageAt:)` runs a page's drawing instructions, forms included, and gives
    every glyph with its font, place and the instruction it came from, plus pictures and
    shapes, all in "display space": the page as shown, turned and cropped, origin at the
    bottom left. `pageContent(at:)` groups glyphs into lines and blocks. `PageGeometry`
    converts to and from the page's own coordinates, which is what PDFKit and
    annotations use.
  - **Text is changed by taking glyphs out and adding new text on top.** A removed glyph
    becomes an equal amount of empty space in its own instruction, so nothing else on
    the page moves. What is added is a new text object at the end of the page. A word
    nobody touched is put back glyph for glyph. A changed word uses the document's own
    font when it has every letter, and an installed font when not.
  - **Installed fonts are put in the document as real fonts** (`Content/EmbeddedFont.swift`):
    the TrueType file is cut down to the glyphs used, by emptying the others so glyph
    numbers stay the same, and embedded as a composite font with a map from codes to
    glyphs and to characters. Text set this way cannot be told from the document's own.
    Fonts that are not TrueType outlines (PostScript-flavored, variable, picture fonts)
    fall back to the font of drawn outlines from Phase 5, which looks a little lighter
    on screen. Forms, stamps and the OCR layer still use the drawn kind.
  - **Edits stay local.** A block is set again from its first changed line. A line that
    starts where an old line started, with all its words still there, is that old line
    again, spaces and all, so the rest of a paragraph and the paragraphs after it keep
    the typesetter's line breaks. When the line count changes they move down or up
    whole. Paragraphs inside a block are told apart by short last lines and by first
    lines set in or out; indents and the space between paragraphs are kept.
  - **Pages set by TeX have no spaces**, only gaps, and their fonts' "space" is zero
    wide. The width of a space is then measured from the block's own gaps.
  - **A single line may grow to the right** up to a margin's distance from the page
    edge; a paragraph keeps its width.
  - **Not editable, on purpose:** turned or slanted text, text inside a form drawn more
    than once, invisible text (OCR layers), and fonts whose codes cannot be mapped to
    characters and back. Such blocks can be selected and copied, and the Format panel
    says why they cannot be changed. Text outside the page's visible box is ignored.
  - **Every content change reloads PDFKit's copy of the document**, since PDFKit cannot
    be told that one page's content changed. The view keeps its exact scroll position.
    On the 158-page Bash manual an edit takes about 50 ms.
  - **Redaction** (`Text/Redaction.swift`): marks are `Redact` annotations, drawn by the
    app as red frames (PDFKit's own drawing of them is a solid gray box, and is switched
    off). Applying removes glyphs whose boxes meet a mark, in the page and in forms it
    draws; repaints the covered part of pictures; removes shapes that lie inside and
    annotations that touch; draws black boxes; then writes the whole file out afresh
    with `rewritten()`, which keeps only what is still referenced. A redacted document
    is therefore never saved by appending. Undo still works until the file is closed.
  - **OCR** uses Vision on a rendering of the page and lays the words over it as fully
    transparent text, each word stretched over its own place. Transparent, not the
    usual invisible text mode, because that mode does not hide fonts made of drawings.
  - **In the app**, Edit is a third toolbar mode beside Markup and Form
    (`Sheaf/Edit`). Clicks go to `ViewerModel.contentMouseDown`; the editor over a block
    is an `NSTextView` set in a matching installed font with the block's line spacing
    and indents; drags show a picture of the thing with alignment guides. Find and
    replace is its own bar and uses the engine's search, not PDFKit's.
  - Not done: resizing a text block's width; rich text inside one block while typing
    (bold or a second font on part of it; what is already there keeps its look);
    changing text in CJK fonts with predefined encodings; clipping paths are not
    considered, so text hidden by a clip is still listed; dragging a picture out of the
    window; copying a picture; right-to-left paragraphs are set left to right; the
    editor shows a stand-in font when the document's is not installed, so its line
    breaks can differ from the page's until the edit is committed.
- 2026‑10‑03, Phase 7 done. 227 engine tests, fuzz clean, and a new corpus pass that turns every file into Word, Excel and PDF/A and compares it with itself, at 0 problems (1,924 files; 12 fonts embedded; 1,726 with nothing left that Sheaf knows to fix). How it is built:
  - **Comparing** (`SheafKit/Review`): pages are matched first (identical pages are fixed
    points; between them, pages pair with the page most like them, and a page with no
    partner is "added" or "removed"), then each pair is compared word by word with
    Myers' shortest-edit algorithm. A change carries the boxes of its words on both
    sides. Pages whose words are equal are also drawn small by PDFKit and compared as
    pictures, which finds changed images and layout ("Looks different"); pages that have
    word changes skip that, since moved text would light up everywhere. The report is a
    PDF the engine writes itself.
  - **Compare window** (`Sheaf/Compare`): two plain `PDFView`s whose scrolling and zoom
    follow each other through the page pairs. Marks are highlight annotations added to
    the on-screen copies only.
  - **Word** (`Convert/WordDocument.swift`): blocks become paragraphs (split where the
    engine sees paragraphs), runs of one font, size, weight, slant and color become runs,
    with alignment, indents and the space above; pictures go inline (JPEGs as they are,
    plain 8-bit pictures as PNG); every page is a section of the page's size and margins.
    No columns, tables or absolute positions: the result is for working with the words.
  - **Excel** (`Convert/Spreadsheet.swift`): one sheet per page. Lines on one baseline
    are a row; columns are bands found from where pieces of text sit above one another,
    with wide pieces (headings) placed last so they do not weld columns together. Cells
    that read as numbers are numbers; codes, dates and phone numbers stay text.
  - **Zip** is written in-house (`Convert/ZipArchive.swift`, deflate through zlib).
  - **PDF/A-2b** (`Convert/Archival.swift`): embeds fonts that are only named, when the
    very font is installed as TrueType and numbered in a standard way (this covers
    Helvetica, Times, Courier, Arial and the like); adds an sRGB output intent and XMP
    with the PDF/A marker; removes scripts, forbidden actions, attachments, XFA, the
    password, LZW compression and image smoothing flags; makes annotations printable.
    It lists what it could not fix: fonts not installed, CMYK colors, annotations
    without a stored picture. **It is not validated**: no validator is bundled and none
    was run. Treat "nothing left to fix" as "nothing Sheaf knows how to check".
  - **Flows** (`Sheaf/Flows`): a flow is a named list of steps (recognize text, reduce,
    watermark, page numbers, rotate, flatten, PDF/A, and Word, Excel or images as a last
    step), saved as JSON in the app's Application Support folder. `FlowRunner` runs
    them off the main thread on the same `Toolbox` functions the menus use. Passwords
    are deliberately not a step: a flow file would have to hold them in the clear.
  - **Shortcuts**: 16 actions now, among them "Run Flow on Files" with the saved flows
    as its choices. Quick Actions come from Shortcuts, as before.
  - Reading a page twice could give different results (ties between equally common
    fonts or sizes were broken by dictionary order, which Swift randomizes per
    dictionary). All such ties are now broken by value, and the corpus pass compares
    every file with itself.
  - Not done: tables in Word output; multi-column reading order; side-by-side visual
    diff overlays (onion skin); comparing annotations and form values; conditional and
    branching flows; a folder-watching runner.
- 2026‑10‑03, Phase 8 done as far as it can be without an Apple developer account.
  - **Russian.** `Sheaf/Resources/Localizable.xcstrings` holds all 764 interface strings
    in English and Russian, with the plural forms Russian needs and singular forms for
    English. `make strings` syncs the catalog with what the build found in the code and
    applies `Scripts/translations/ru_*.py`; it lists anything untranslated. The Finder's
    Services menu and document kinds are translated in `ru.lproj`. The engine's own
    error messages and the Help Book are English only.
  - **Help Book.** `Scripts/make-help.py` holds every page and writes
    `Sheaf/Resources/Sheaf.help` (13 pages, light and dark, with a search index), which
    goes into the app as a folder. Help ▸ Sheaf Help opens it.
  - **Tips.** Three TipKit tips on the Edit, Organize Pages and Markup toolbar buttons,
    one at a time, each gone for good once its feature is used. Help ▸ Show Tips Again.
  - **Keyboard and VoiceOver.** In Edit mode Tab and ⇧Tab step through the page's text
    and pictures in reading order and each selection is announced. Icon-only buttons
    all carry names. The pages themselves are PDFKit's and read as PDFKit reads them.
  - **Performance**, measured on a 632-page document and on a 209 MB one of large
    photographs: opening is immediate for both (nothing is read until needed); an edit
    takes 40 to 80 ms on either. Find and replace was the slow part and was reworked:
    search runs on all cores off the main thread (632 pages: 9.4 s to about 2 s), fonts
    are read once per document, and Replace All changes each page in one pass in the
    background (2,368 replacements on 552 pages: about 15 s, with the window live).
    Typed text in one typeface now shares one embedded font per document, which grows
    as needed, where it used to add a font per edit.
  - **Shipping.** `Scripts/release.sh` archives a Release build, signs it, notarizes
    and staples the app, packs a disk image and does the same for it. It has been run
    without a Developer ID, which gives an image that works on this Mac only; the
    signed path is written from the documentation and untested. `RELEASING.md` has the
    steps that need your accounts.
  - **Icon.** `Scripts/make-icon.swift` draws the app icon (fanned sheets held by a
    band) at every size into the asset catalog. A first version, not a designer's.
  - **Sparkle is wired but not installed.** `Sheaf/App/Updater.swift` compiles its
    "Check for Updates…" command only when the Sparkle package is in the project.
    Adding it downloads third-party code and needs an update feed and signing key, so
    it is left for you; `RELEASING.md` lists the five steps.
  - **A change made outside event handling was not counted as unsaved.** AppKit closes
    an undo step, and only then marks the document as changed, at the end of handling
    an event. Results of background work (Replace All, Recognize Text, Reduce File Size,
    flows) arrive outside any event, so the step stayed open and quitting before the
    next event would not have saved them. `SheafDocument.install` now posts an empty
    event after registering an undo step, which closes it at once. Found through the
    automated runs, where a rotation was not saved on quit; it is saved now.
  - **Arranging like Pages, 2026-10-04.** After Phase 8, the picture and text tools were
    brought closer to what Pages offers on the right and on right-click, as far as a
    PDF can carry it:
    - *Stacking order.* A PDF page has no layers: things cover what was drawn before
      them. Bring to Front, Send to Back, Forward and Backward move a picture or a
      block of text in the page's own drawing order. A picture is lifted out together
      with the state it was drawn in (clip, transparency, colors, marked sections) and
      put down again; where it lands in the middle of the page's drawing, the state in
      force there is closed and set up again after it. A move is only offered when
      something overlaps, and nothing goes behind what covers the whole page.
      Annotations are ordered among themselves by their place in the page's list.
    - *Pictures* can be turned (Command-drag a handle), mirrored, made see-through,
      masked (the whole picture stays in the file; a clip rectangle shows part of it),
      copied, cut, duplicated (the copy shares the image), and have their background
      taken out with the system's subject detection. A changed picture is kept in one
      small group of operations, `q [gs] cm [re W n] Do Q`, which is edited in place.
    - *Left out, and why:* Distribute and aligning things to each other need more than
      one thing selected, which the editor does not have yet. Border, shadow and
      reflection would have to be drawn as separate shapes that nothing ties to the
      picture afterwards. Text wrap, object placement, lock, group, title and caption
      are Pages document features with no place in a PDF page. Adjust Image, Super
      Resolution, Ask Siri, Playground and Pixelmator were not attempted.
    - Shift-Command-F is now Bring to Front, as in Pages. The form toolbar moved to
      Shift-Command-M.
  - **Annotations are drawn by Sheaf, 2026-10-04.** A drawn signature looked blocky
    when zoomed in. PDFKit keeps every annotation that has a look of its own in a
    separate layer holding one pixel per point of the page, whatever the zoom or the
    display, and nothing in the file changes that. So signatures, stamps, shapes,
    drawings, notes and text boxes are now drawn by `PageAnnotationView`, a view
    PDFKit puts over each page and moves and zooms with it. Each annotation is a
    picture made from the look stored in the file, at the zoom in use, and made again
    when the zoom changes. PDFKit's own copies are switched off on screen. Highlights,
    underlines, links and form fields are still PDFKit's. Drags and new shapes are
    drawn the same way, so they are sharp while they move, which they were not before.
  - **Save options, 2026-10-04.** Preview's save dialog offers a format, PDF/A, two
    choices about pictures and permissions. Sheaf had these as separate commands.
    File ▸ Export… now has them in its panel, with the format. File ▸ Save As…, and the
    first Save of a new document, have them too. SwiftUI owns the document class and
    its save panel, so `SavePanelOptions` gives that class an override of AppKit's
    `prepareSavePanel(_:)`, to add the choices, and of `save(to:ofType:for:completionHandler:)`,
    to make the document what was chosen just before it is written. With nothing
    chosen both pass straight through. The change to the document is an undo step
    ("Save Options"), so the window and the file agree and going back is possible.
    Linearized PDF and Quartz filters are not offered: the engine does not write
    linearized files, and color filters would mean redrawing every page through
    Core Graphics, which loses forms, links and text structure.
  - **Text boxes can be resized, 2026-10-04.** Selected text has a handle on each
    side, and so has the editor while typing. A PDF stores no box, only where each
    letter is, so resizing sets the words again between the new sides
    (`TextRestyle.left` and `.right`), keeping the top line where it was. The same
    report showed an address opening as one run-on paragraph. Lines are now only
    joined into a paragraph when they are long enough to be running text (34
    characters or more in the longest, or justified); blocks of short lines keep
    every line break, and may grow to the right like a single line does.
  - **The Format panel is Sheaf's own column, 2026-10-04.** SwiftUI's inspector
    reached up behind the toolbar, to the top of the window, which read as the
    toolbar being cut short. The panel is now a column of the detail area: it starts
    under the toolbar, slides in from the right, and is 280 points wide. Its width is
    no longer draggable, and the View menu's Show Inspector command is Sheaf's own.
    It is colored like the system's inspector (the window's color with 6% of the text
    color over it, its forms' own backgrounds hidden), and rows of tools run the
    width of the window above both the pages and the panel. Pages no longer pass
    under the toolbar: the toolbar is see-through, so it showed pages under one part
    and the panel's backdrop under another, as two toolbars side by side.
  - **Default PDF app, 2026-10-04.** Sheaf asks once, at its first launch, whether to
    open PDFs from now on, and Settings ▸ General has a menu of every app that opens
    PDFs. Both go through `NSWorkspace.setDefaultApplication(at:toOpen:)`. Whether
    macOS lets a sandboxed app make that change was not tried, since trying changes a
    setting of the person's Mac; when it refuses, an alert explains the Finder's way.
  - **Reply from a Mail attachment, 2026-10-04.** Preview offers to reply when a
    changed attachment is closed. Sheaf reads who sent a file from the "where from"
    attribute Mail puts on attachments (sender, subject, a link to the message), offers
    Reply, New Mail Message, Close and Cancel when such a document is closed after a
    change, and has File ▸ Reply to Sender…. The message is made through the system's
    compose-mail sharing service, addressed to the sender with "Re:" and the subject.
    It is not threaded to the original: replying to a message in the mailbox takes
    access to Mail that a sandboxed app does not have. The offer on closing is an
    override of `canClose(withDelegate:shouldClose:contextInfo:)` on SwiftUI's
    document class, next to the save panel ones.
    Mail's attachments open as untitled copies with no file of their own, so the first
    version, which looked at the document's file, never saw one. Where a document is
    read from is now noted as it is read (an override of `read(from:ofType:)`, set up
    at launch on the classes SwiftUI makes for the app's document types), and the offer
    is also made on Save, by overriding the Save command itself: the documented
    `runModalSavePanel` is not what AppKit goes through for these documents.
    The file Mail hands over turned out to say nothing about its message that a
    sandboxed app can read: no "where from" attribute, and a quarantine record whose
    sender sits in a database outside the sandbox. So Sheaf asks Mail, by AppleScript,
    which of the selected messages has an attachment of that name, and has Mail start
    the reply itself, which is then a real reply in the conversation. This takes the
    Automation permission for Mail (`com.apple.security.temporary-exception.apple-events`
    and `NSAppleEventsUsageDescription`); macOS asks the person once. That exception
    entitlement is fine for Developer ID distribution and would need review for the
    Mac App Store.
    Adding the attachment by script makes Mail write the reply's body again from what
    the script can see, and the quote Mail had put there is lost. Sheaf therefore
    writes the original's text into the reply itself, as plain quoted lines. Preview
    keeps Mail's own rich quote; it does not go through scripting.
    Plain quoted lines were not good enough: the thread did not look like one. Tried
    against Mail, with the person's leave: a script sees none of a reply's quote, any
    scripted attachment wipes it, and opening a file with Mail starts a new message.
    What does work is a message file marked `X-Unsent: 1`: Mail opens it as a message
    being written. So Sheaf asks Mail only for the original's source, and writes the
    reply whole (`MailDraft`): To from Reply-To or From, "Re:" and the subject,
    In-Reply-To and References, the original's own HTML (or its plain text) inside a
    `blockquote type="cite"` under Mail's "On …, at …, … wrote:" line, the pictures the
    text shows carried over by Content-ID, and the PDF. Mail then opens that file. The
    From account is Mail's default one and the original is not marked as replied.
  - **Apple Intelligence, 2026‑10‑04.** Pages (Creator Studio 15.4) was read for what it
    offers: Writing Tools, Image Playground, Super Resolution, Auto Crop, Remove
    Background and image descriptions use what is built into macOS; its Generate Image,
    Generate Shape and Generate Document go to OpenAI and Google through a subscription
    and were left out, as the brief was the built‑in models.
    The language model is `FoundationModels`' `SystemLanguageModel` (on this Mac: 8K
    tokens of context, takes pictures on macOS 27). A document does not fit, so
    `DocumentReader` reads it in parts: notes on each part, then the summary from the
    notes (condensed again when the notes are too long). The budget per part comes from
    the model's own token count of a sample of the document, since tokens per character
    differ by language. Summaries use `permissiveContentTransformations` guardrails, so a
    contract that lists crimes is summed up like any other text. Those guardrails cover
    plain text only: asked to fill in a structure, the model refused such passages. So
    answers are asked for as plain text, and the properties fall back to plain lines.
    Questions are answered from the passages that match best. The system's sentence and
    contextual embeddings ranked passages of the bash manual poorly and took 7 to 20 s,
    so matching is by words (BM25) with three things that mattered in trials: words are
    weighted by what kind they are (in a manual "how" and "do" are rare and looked
    important), strings with signs or digits are matched as they stand ("-e"), and the
    model first names words to look for, translated when the question is in another
    language. The first passage of the document always goes along. The model was asked
    to name its pages and to mark missing answers in several forms; it kept to none of
    them reliably, so it is asked only for the answer or "N/A", and the pages are those
    whose passages share most words with the answer.
    Super Resolution is VideoToolbox's `VTSuperResolutionScalerConfiguration` (4×, input
    up to 1920 px, model downloaded by macOS on first use; Sheaf asks before a download).
    The result is stored as a JPEG capped at 4096 px. Auto Crop is Vision's
    attention saliency, applied as an ordinary mask. Descriptions use the model's vision
    input, macOS 27 only. Image Playground is the system sheet.
    The Summary panel shares the right column with the Format panel. Edit ▸ Writing
    Tools is built from AppKit's own items (`NSMenuItem.writingToolsItems`), since
    SwiftUI's menu did not get them by itself.
  - **Private Cloud Compute, 2026‑10‑04.** Asked for as an option. `DocumentReader` takes
    a `ReadingEngine` (this Mac, or `PrivateCloudComputeLanguageModel`: 32K tokens of
    context, reasoning), chosen in Settings ▸ Intelligence and in the Summary panel, with
    larger parts and longer notes for the cloud model. When the cloud fails (network,
    limit, anything but a stop or an empty document) the model on this Mac does the work
    and the result says why. It cannot be used yet: the service wants the managed
    entitlement `com.apple.developer.private-cloud-compute`, which Apple grants on
    request. Found by trying: an ad hoc signed build gets "Operation not permitted"
    (ModelManagerError 1046), a development‑signed one is stopped by the framework with a
    fatal "Missing entitlement". So Sheaf reads its own entitlements and offers and uses
    the cloud model only when the key is there. Until then the choice is hidden: no
    Settings pane, nothing in the panel, no mention in the help. Steps to get it are in
    RELEASING.md.
  - **Privacy and legal audit, 2026‑10‑14.** Checked against a list of ten legal traps of
    web apps; most do not apply (no backend, no accounts, no network access, no analytics,
    no payments, no email). Fixed what did: saved signatures are sealed with AES‑GCM, the
    key in the login Keychain (`SignatureVault`), the old plain file migrated and removed;
    the author name written into markup is a setting that may be empty (Preferences
    `markup.authorName`); notes made from Apple Intelligence say so and are signed
    "Apple Intelligence"; the panel's caption names Apple Intelligence; pictures from Image
    Playground carry IPTC `trainedAlgorithmicMedia` XMP on the image XObject (engine
    `addImage(…, generatedBy:)`), since re‑encoding into the PDF drops Apple's own mark;
    copies made for Mail and scanned pages are removed after use and swept at launch
    (`TemporaryFiles`); a privacy page in the Help book, linked from the Help menu; labels
    for three icon‑only buttons. Left open: documents Sheaf writes are untagged (no PDF/UA),
    and US export classification for the AES encryption Sheaf includes.
  - **Invisible typed text in LaTeX PDFs, 2026‑10‑15.** Reported on a Beamer slide: text added
    to a title was kept but did not show until edited again. pdfTeX gives every code in a
    range a width, also the ones whose glyphs it left out of the subset, and the engine took a
    width as proof of a glyph, so "5" and "j" were written in the slide's font and drew
    nothing. `PageFont` now also asks the font program which glyphs it carries: the
    descriptor's CharSet, or the CharStrings in the eexec part of a Type 1 program
    (`Type1Program`). Compact (CFF) programs are still judged by their widths only.
    Text already written that way is set again when its block is next edited
    (`PageFont.draws`). Found on the user's own file; my first test runs on it saved edits
    into it, since the app saves in place when it quits. Restored from the macOS version
    store, and `Scripts/snapshot.sh` now always opens copies.
  - **Editor in the document's own font, 2026‑10‑15.** The editor showed text in an
    installed look-alike (Helvetica for LaTeX's CMSS), which is wider, so lines broke
    differently and the text looked resized. The engine now tells which embedded font
    program a block uses (`TextBlock.fontProgramID`, `PDFEditor.fontProgram`), and the app
    loads it with `CTFontManagerCreateFontDescriptorFromData` (works for the Type 1 subsets
    of pdfTeX), with the installed font in its cascade list for letters the subset lacks.
    It is used only when macOS finds glyphs for the block's letters and their widths match
    the page's within 3% (`EditorFont`), since a subset may number its glyphs its own way.
  - **Tools at the side, as in Inkpage, 2026‑10‑15.** The user found Inkpage, their note-taking
    app, clearer, and asked for its design patterns. Taken over: one
    floating glass strip of tools at the side of the pages (`ToolStrip`), the options of the
    tool in hand in a glass panel beside it, opened and closed by pressing the tool again;
    labels that appear at once on hover (`named`); Inkpage's round colour swatches and dotted
    level slider (`FloatingControls`); a shield under floating bars so the page does not take
    their clicks; the zoom floating at the foot; the strip movable to either side. Sheaf's
    ways of working (marking up, editing the page's content, building a form) stay as they
    were underneath; taking a tool switches to its one (`ViewerModel.take`). What is
    selected shows its old Format panel settings in the same floating panel. The three rows
    of tools, the Format column, and the Markup, Edit, Form, Format and zoom items of the
    toolbar went. The pages keep a 64‑point margin on the strip's side so it never covers them.
- **2026‑10‑15 Paragraph boxes are remembered on the page.** A centered or right-aligned
    paragraph's lines are narrower than the box they were set in, and nothing in a PDF says
    how wide that box was, so centering and then going back to the left drifted. Sheaf now
    notes the box it set a paragraph in under a private `SheafTextBoxes` key on the page
    (sides and top, as displayed) and uses it the next time the same paragraph is set.
    Other programs ignore the key; Remove Hidden Information takes it out with other
    private data. A single line with no remembered box uses the page's text column: from
    where its text starts furthest left to where its paragraphs reach furthest right.
- **2026‑10‑15 A centered paragraph whose full lines reach both sides** used to be read as
    justified, because full lines look the same either way. The last line decides now:
    short and in the middle means centered, short against the right side means right.
- **2026‑10‑15 Removing hidden information writes the file afresh**, like redaction, so
    removed objects and anything deleted earlier are gone from the file, not just unlinked.
- **2026‑10‑15 Rich text, web page and plain text export** go through the Word converter
    and AppKit's own readers and writers, so all four exports agree on paragraphs and styles.

