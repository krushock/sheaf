# Things to check by hand

Sheaf is built and tested from the command line. The checks drive the app through a debug
hook and take screenshots, but they cannot click, type, drag, or use hardware. Everything
below works in automated checks or is written to the documented API, and still needs a
person to try it once. Tick items off as you go; anything that misbehaves is worth a note.

Open the app with `make run`.

## Basics (Phases 0–1)

- [ ] Launching shows the Welcome window. Opening a document closes it.
- [ ] Welcome: single click selects a recent, double click opens it, the search field filters,
      the icon/list switch works, right click offers Open and Show in Finder.
- [ ] Keyboard shortcuts: ⌘F focuses search, ⌘G and ⇧⌘G step through results, ⌥⌘G opens Go to Page,
      ⌘1 ⌘2 ⌘3 switch layout, ⌘0 ⌘9 ⌘+ ⌘− zoom, ⌥⌘1…4 switch the sidebar, ⇧⌘1 shows Welcome.
- [ ] Clicking a thumbnail, a table of contents entry, and a search result each jump to the right place.
- [ ] Trackpad pinch zooms; scrolling passes under the toolbar.
- [ ] File ▸ Print shows the print sheet and prints.
- [ ] File ▸ Export: the format menu lists PDF, PNG, JPEG, TIFF, HEIC and each writes a usable file.
- [ ] File ▸ Save, Save As, Duplicate, Rename, Move To, Revert To behave as in Pages.
- [ ] A password-protected PDF asks for its password; a wrong one is refused.
- [ ] Window tabs: View ▸ Show Tab Bar, Window ▸ Merge All Windows.
- [ ] Settings: each setting takes effect on the next document opened.
- [ ] Opening a corrupt PDF shows an alert and nothing else odd happens.

## Markup (Phase 3)

- [ ] With the Highlight tool active, dragging across text highlights it. Same for Underline and Strikethrough.
- [ ] With text already selected, clicking the Highlight button marks it at once.
- [ ] Rectangle, ellipse, line, arrow: drag to draw; a single click makes one at a default size.
- [ ] Draw: several strokes in a row, each undoable.
- [ ] Text: drag a box, type, click away. Double click reopens it for editing. An empty box disappears.
- [ ] Note: click places it and the Comment field in the inspector takes the keyboard.
- [ ] Link: drag a box, then set a web address or page in the inspector. With markup hidden, clicking it follows it.
- [ ] Select, move, resize by handles, arrow-key nudge (⇧ for bigger steps), Delete.
- [ ] Each action is its own Undo step, and the Edit menu names it ("Undo Add Rectangle").
- [ ] Inspector: color, fill, line width, opacity, arrowheads, font, size, alignment all apply live.
- [ ] Dragging a slider or the color wheel makes one Undo step, not dozens.
- [ ] Stamps menu and Custom… stamp.
- [ ] Sign: draw a signature with the trackpad, type one, import a photo of one. Saved ones reappear in the popover and can be removed.
- [ ] Signature from an iPhone: with the Image tab open, File ▸ Import from iPhone ▸ Take Photo.
- [ ] Tools ▸ Add Bookmark (⌘D); rename and delete from the sidebar's right-click menu.
- [ ] Right click an annotation in the sidebar ▸ Reply…; the reply shows indented.
- [ ] Tools ▸ Flatten Annotations… then check the file in Preview.
- [ ] Edit, quit, reopen: everything is still there. Open the same file in Preview and in a browser: it looks the same.
- [ ] An annotated file that was digitally signed beforehand still verifies in Acrobat (saving only appends).

## Pages (Phase 4)

- [ ] Toolbar ▸ Organize Pages (⌥⌘O) shows the grid; Done, Esc, or double-clicking a page goes back.
- [ ] Click, ⇧-click, ⌘-click and dragging a box across pages select them. ⌘A selects all.
- [ ] Drag one page, then several, to a new place. The gap opens where they will land, and one Undo puts them back.
- [ ] Drag a PDF and a picture from the Finder into the grid, between two pages.
- [ ] Drag pages from the grid to the Finder. One PDF with those pages appears.
- [ ] Delete key, and Edit ▸ Cut, Copy, Paste, Delete, with pages selected. Paste into another Sheaf window and into Preview.
- [ ] Right-click a page, and the empty area, in the grid. Every menu item works.
- [ ] The size slider under the grid. The size is remembered for the next window.
- [ ] Tools ▸ Rotate Left (⌘L) and Rotate Right (⌘R), in the grid and while reading.
- [ ] Tools ▸ Pages ▸ Split Down the Middle on a scan of an open book.
- [ ] Sidebar thumbnails: drag one to reorder, drop a file between two, right-click for the page menu.
- [ ] Edit ▸ Insert ▸ Blank Page, Pages from File…
- [ ] After removing a page that bookmarks or links pointed to, those bookmarks and links are gone and the rest still work.

## File tools (Phase 4)

- [ ] Tools ▸ Watermark…: text and image, every control changes the preview, Add puts it on the chosen pages, Undo removes it.
- [ ] Tools ▸ Header and Footer…: the Insert buttons add to the field last clicked in; numbers are right on every page.
- [ ] File ▸ Document Info… (⌘I): change the title, save, reopen. Finder's Get Info shows the new title.
- [ ] File ▸ Set Password…: set one, save, reopen (it asks), open in Preview (it asks). Change Password and Remove Password. Undo after each.
- [ ] "Limit What Others Can Do" with an owner password: Preview refuses to copy text or print as set.
- [ ] File ▸ Reduce File Size… on a large PDF with photos: the progress bar moves, Stop stops, the result looks right, Undo restores the original size.
- [ ] File ▸ Split into Documents…: each of the four ways; the files appear in the chosen folder and the Finder shows them.
- [ ] File ▸ Export as Images…: each format and resolution; Stop midway.
- [ ] File ▸ New from PDFs… (⌥⌘N): add, drop, reorder, remove files; a page range for one of them; Merge opens an untitled document with a bookmark per file.
- [ ] In New from PDFs, a protected PDF shows Enter Password…; a wrong password asks again, the right one shows its page count, and Merge then includes its pages.
- [ ] Inserting or dropping a protected PDF into a document asks for its password; Skip leaves it out and still adds the other files.
- [ ] File ▸ New from Images… (⇧⌘N): page size and margins; "Straighten Photos of Documents" on a real phone photo of a sheet of paper.
- [ ] The Welcome window's six actions, including Reduce File Size… and Split a PDF…, which ask for a file and then show the tool on it.
- [ ] Opening a JPEG, PNG and HEIC directly. An iPhone photo keeps its colors (it is stored with its Display P3 profile).

## Needs hardware or another app (Phase 4)

- [ ] Edit ▸ Insert ▸ Pages from Scanner…: a USB and a network scanner appear, a scan becomes a page. If a network scanner does not appear, the app may need the outgoing network entitlement; open an issue.
- [ ] File ▸ Import from iPhone ▸ Scan Documents and Take Photo, with a document window in front: the result is added after the current page. A photo of a sheet of paper arrives squared up.
- [ ] Shortcuts app: the 11 Sheaf actions are listed under Sheaf, each runs on a file and passes its result on. Five of them also appear in Spotlight.
- [ ] A shortcut built from a Sheaf action with "Use as Quick Action" ticked appears in Finder's Quick Actions.
- [ ] Finder ▸ right-click a PDF or pictures ▸ Services (or Quick Actions): "Merge with Sheaf", "Make PDF with Sheaf", "Reduce File Size with Sheaf". They may need enabling in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services.
- [ ] A reduced PDF opens in Acrobat and in Chrome without warnings. One that was PDF 1.3 keeps that version number while using a newer file layout; say if anything objects.

## Forms (Phase 5)

- [ ] Open a real fillable PDF of your own, such as a tax or bank form. Every field is tinted; click each kind and fill it in.
- [ ] Text field: click, type, Return. Tab and ⇧Tab move between fields in a sensible order; Esc cancels what was typed.
- [ ] A field with several lines takes Return as a new line. A field with a length limit beeps at the limit.
- [ ] Checkbox and radio buttons switch on click; with the keyboard, Tab to one and press Space.
- [ ] Dropdown: the menu opens at the field with the current choice ticked.
- [ ] Date field: the calendar opens under the field; Set Date, Today and Clear work.
- [ ] Signature field: the saved signatures appear; choosing one puts it inside the field.
- [ ] Each fill is one Undo step.
- [ ] Save, then open the file in Preview, in Chrome and in Acrobat. Every value shows once, in the right place, and can still be changed there. Check a value in Cyrillic too.
- [ ] Fill a form in Preview or Acrobat, save, and open it in Sheaf: the values show.
- [ ] Tools ▸ Form ▸ Reset Form… and Flatten Form…. After flattening, the text can still be selected and searched in Preview.
- [ ] Toolbar ▸ Form (⇧⌘F) shows the form tools. Each of the six tools: drag out a field, and click once for a field of the usual size.
- [ ] Select a field, move it, resize it by its handles, nudge it with the arrow keys, delete it.
- [ ] The Format panel for a field: rename it, give it a label, make it required, change text size, alignment, colors, border and background.
- [ ] A dropdown's options: add, rename, remove. A second radio button drawn while one is selected joins its group, and only one of the group can be on.
- [ ] Detect Fields on a scanned or printed form with boxes, lines and "Name: ______" blanks. Fields land on the right places with sensible names; boxes that hold printed text are skipped.
- [ ] Annotations and stamps from Phase 3 are sharp when zoomed in. While something is being dragged it is slightly soft; that is known.

## On macOS 26

- [ ] Everything above. Sheaf is built for macOS 26 and later but has only ever run on macOS 27.
