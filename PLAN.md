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

### Phase 6 — Content editing (3–4 weeks, the core)
Text layout model, fonts (time‑boxed subsetter + CoreText matching), EditOverlay with
Pages behaviors (section 5), image move/resize/replace/paste/delete, find & replace,
redaction (manual + auto patterns + preview + apply), OCR text layer. Exit criteria:
edit a word in a typical Word‑exported PDF and an InDesign PDF with no visible
difference; redacted text absent from extraction; all saves open in Preview and Acrobat.

### Phase 7 — Review, convert, automate (1.5 weeks)
Compare (synced scroll, text diff + visual diff, change list, report export), PDF→Word
and PDF→Excel via in‑house OOXML writer (marked Beta), PDF/A‑2b export, Flows (saved
step pipelines, batch runner, exposed as Shortcuts actions and Quick Actions).

### Phase 8 — Polish & ship (1 week)
String Catalogs (en, ru), VoiceOver, keyboard navigation, Help Book, TipKit onboarding,
performance pass on 500+ page / 200 MB files, signing, notarization, DMG, Sparkle.

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

