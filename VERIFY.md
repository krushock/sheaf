# Things to check by hand

Sheaf is built and tested from the command line. The checks drive the app through a debug
hook and take screenshots, but they cannot click, type, drag, or use hardware. Everything
below works in automated checks or is written to the documented API, and still needs a
person to try it once. Tick items off as you go; anything that misbehaves is worth a note.

Open the app with `make run`.

## Basics (Phases 0–1)

- [ ] Launching shows the Welcome window. Opening a document closes it.
- [ ] Welcome: the window drags by the whole "Recents" header and by the left pane, not only by its top edge. The search field, the view switch and the action buttons still work.
- [ ] Showing and hiding the sidebar (the toolbar menu, ⌥⌘1 to ⌥⌘4) slides it in and out, as in Apple's apps.
- [ ] The area behind the pages is a gray a step darker than the sidebar, in light and in dark mode, and the toolbar lines up with it. Dark mode was not looked at.
- [ ] The Format panel on the right always starts under the toolbar, which runs the full width of the window above it: while reading, with the markup, edit and form tools out, in the organizer, in full screen, and after resizing the window (changed 2026-10-04: it is now Sheaf's own column, 280 points wide, not the system inspector). It is the same light gray as the system's inspector, with its groups of controls a step darker, and the row of tools (with Done at the far right) runs across the window above it. Check it in dark mode too, which I did not see. It slides in and out. Its width can no longer be dragged; say if you want that back.
- [ ] View ▸ Show Inspector / Hide Inspector (⌃⌘I) still shows and hides it, and so does the paintbrush button.
- [ ] Double-clicking the toolbar's empty space zooms the window (or minimizes it, per System Settings ▸ Desktop & Dock), including right beside the document's name. Double-clicking the name itself still does what it does in other apps.
- [ ] Welcome: single click selects a recent, double click opens it, the search field filters,
      the icon/list switch works, right click offers Open and Show in Finder.
- [ ] Keyboard shortcuts: ⌘F focuses search, ⌘G and ⇧⌘G step through results, ⌥⌘G opens Go to Page,
      ⌘1 ⌘2 ⌘3 switch layout, ⌘0 ⌘9 ⌘+ ⌘− zoom, ⌥⌘1…4 switch the sidebar, ⇧⌘1 shows Welcome.
- [ ] Clicking a thumbnail, a table of contents entry, and a search result each jump to the right place.
- [ ] Trackpad pinch zooms. Pages no longer pass under the toolbar (changed 2026-10-04): the toolbar is the same plain band from one side of the window to the other in every mode, with one line under it or under the row of tools. Say if you miss the pages showing through.
- [ ] The toolbar's zoom button shows the zoom as a percent and opens a menu like the one in Pages: the page layouts, 25% to 400%, Fit Width (⌘9) and Fit Page (⌘8). The current choice is checked.
- [ ] With Fit Page chosen, resizing the window keeps the whole page in view. Pinching or picking a percent ends it.
- [ ] File ▸ Print shows the print sheet and prints.
- [ ] File ▸ Export: the format menu lists PDF, PNG, JPEG, TIFF, HEIC and each writes a usable file.
- [ ] File ▸ Save, Save As, Duplicate, Rename, Move To, Revert To behave as in Pages.
- [ ] A password-protected PDF asks for its password; a wrong one is refused.
- [ ] Window tabs: View ▸ Show Tab Bar, Window ▸ Merge All Windows.
- [ ] Settings: each setting takes effect on the next document opened.
- [ ] Opening a corrupt PDF shows an alert and nothing else odd happens.

## Default PDF app (added 2026-10-04)

- [ ] I did not change your default PDF app: that is a system setting, and yours to change. So the two things that change it are untested: the Use Sheaf button and picking an app in Settings.
- [ ] The first time Sheaf opens it asks once, "Make Sheaf your default PDF app?", on the Welcome window. To see it again: `defaults delete com.valeryburtsev.Sheaf general.askedAboutDefaultApp` and reopen Sheaf while another app is the default. It does not ask when Sheaf already is.
- [ ] Use Sheaf: afterwards a PDF double-clicked in the Finder opens in Sheaf. macOS may show its own confirmation first. If it refuses (the app is sandboxed, and I could not find out without trying), an alert says so and explains the Finder's Get Info way; tell me, so that I can look for another route.
- [ ] Not Now: nothing changes and it never asks again.
- [ ] Settings ▸ General ▸ Default PDF app lists every app that opens PDFs, Sheaf first, with the current one checked. Choosing another changes it; choosing Preview puts things back. The row follows a change made elsewhere, such as in the Finder, when you come back to Sheaf.
- [ ] Settings now opens on the pane you last looked at.

## Documents from Mail (added 2026-10-04)

None of the steps that talk to Mail were run by me: they read your mailbox and write a draft in your account.

- [ ] Open a PDF attachment from a message in Mail with Sheaf, leaving that message selected in Mail. It opens as an untitled copy. Change something and press ⌘S. The first time, macOS asks whether Sheaf may control Mail: allow it. A sheet then offers Reply to <first name>…, New Mail Message, Save… and Cancel, as Preview does.
- [ ] Reply to <name>… opens a reply in Mail, addressed to the sender, with "Re:" and the subject, and with the changed PDF attached under the attachment's own name. Nothing is sent until you send it. Check the attachment is there and opens.
- [ ] The earlier message is quoted in the reply the way Mail quotes it (changed twice on 2026-10-04: first the quote vanished, then it was plain ">" lines). Sheaf now writes the whole reply itself as a draft and has Mail open it: the original keeps its formatting, links and pictures, sits behind Mail's quote bar, under "On <date>, at <time>, <sender> wrote:". I checked with a made-up message that Mail opens such a draft from the sandboxed app, and you confirmed the look for a test draft. Check a real one: a long thread, a message with pictures in the text, and a plain-text message.
- [ ] Send one such reply to yourself and look at it where it arrives: it should fall into the same conversation as the original (the draft carries In-Reply-To and References; whether Mail keeps them when sending I could not try, since I send nothing).
- [ ] Known differences from Preview: Mail picks the From account by its own default rather than by the mailbox the message is in, the original is not marked as replied in the message list, and the original's other attachments are not sent back (pictures shown inside the text are).
- [ ] If Mail has another message selected by then, or you answered no to the question about controlling Mail, the sheet has no Reply button, only New Mail Message. Allow it later in System Settings ▸ Privacy & Security ▸ Automation.
- [ ] File ▸ Reply to Sender… does the same at any time for a document from Mail, and says so when the message is not selected.
- [ ] Close the changed copy without saving: the same offer, with Close in place of Save…. After a message was started for the document as it is, closing does not ask again.
- [ ] Save… goes on to the usual save dialog. New Mail Message opens an empty message with the PDF attached.
- [ ] A document that did not come from Mail saves and closes without any question, File ▸ Reply to Sender… is dimmed, and Sheaf never talks to Mail.
- [ ] If something here does not work, run this right after and send me the output. It has no names or addresses:
      `/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.valeryburtsev.Sheaf"'`

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

- [ ] Insert ▸ Blank Page is now a menu of sizes (Edit ▸ Insert, the + button and the right-click menu of the organizer, right-click on a thumbnail): "Same as Page N" for the page it goes after and for the other sizes the document has, then A3, A4, A5, US Letter, US Legal, Tabloid, then Other Size…
- [ ] Other Size… shows a sheet with the paper, Portrait or Landscape, and width and height in millimeters (inches with US region settings). Typing a size switches the paper to Custom; typing A4's numbers switches it back to A4. Check a landscape A3 and an odd custom size, and that each is one Undo step.
- [ ] In a document with pages of different sizes, the names in the menu are right: a known paper by name ("A4", "A4 Landscape"), anything else by its measurements.

- [ ] File ▸ Save As… (and the first Save of a new document) shows options under the name and place, as Preview does: Create PDF/A, Optimize images for screen, Save images as JPEG, Permissions…. With nothing ticked the file is saved exactly as before.
- [ ] Tick one option at a time and save under a new name. Open the result in Preview and Acrobat: PDF/A is reported as such (it is not validated by me), pictures are smaller with the two image options, and Permissions… asks for the password you typed. The window then shows the saved version, the title bar does not say Edited, and Undo ("Save Options") goes back to the document as it was.
- [ ] Cancel the Save As panel after ticking options, then press ⌘S: nothing is applied.
- [ ] Permissions… opens a small panel beside the button, inside the save dialog. Check it opens, takes typing, and closes with Done, also when the save dialog is expanded to show the file browser. This could not be driven by my automated runs.
- [ ] File ▸ Export… has the same options plus Format (PDF, JPEG, PNG, TIFF, HEIC). A picture format exports the page being read, with a resolution and, for JPEG and HEIC, a quality. The file name's extension follows the format.
- [ ] Preview's "Create Linearized PDF" and Quartz filters (Black & White, Sepia and so on) are not offered. Say if you need either.

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
- [ ] Toolbar ▸ Form (⇧⌘M, changed from ⇧⌘F, which is now Bring to Front as in Pages) shows the form tools. Each of the six tools: drag out a field, and click once for a field of the usual size.
- [ ] Select a field, move it, resize it by its handles, nudge it with the arrow keys, delete it.
- [ ] The Format panel for a field: rename it, give it a label, make it required, change text size, alignment, colors, border and background.
- [ ] A dropdown's options: add, rename, remove. A second radio button drawn while one is selected joins its group, and only one of the group can be on.
- [ ] Detect Fields on a scanned or printed form with boxes, lines and "Name: ______" blanks. Fields land on the right places with sensible names; boxes that hold printed text are skipped.
- [ ] Signatures, stamps, shapes, drawings and text boxes are sharp at every zoom, also while they are being dragged or drawn (changed 2026-10-04: Sheaf now draws them itself over the page, because PDFKit keeps annotations at one pixel per point). Zoom to 400% and 800% on a signature you drew.
- [ ] While pinching to zoom, annotations stretch with the page and turn sharp a moment after you stop. While scrolling fast they stay glued to the page. Say if they ever lag, jump or flicker, including right after an edit or Undo.
- [ ] On a page that is rotated, and on one with a crop box that does not start at the corner, annotations sit exactly where their selection frames are.
- [ ] Thumbnails in the sidebar and the organizer show the annotations. File ▸ Print prints them. File ▸ Export of a page as a picture includes them.
- [ ] A drawn signature is no longer cut off at its edges, and the drawing pad and the list of saved signatures show the same smooth line as the page. Signatures saved before this change still work.

## Editing text and pictures (Phase 6)

- [ ] Toolbar ▸ Edit (⇧⌘E) shows the editing tools and a thin frame around every piece of text and every picture.
- [ ] Open a PDF exported from Word and one from InDesign. Double-click a paragraph, change a word, click away. At 400% the new word cannot be told from its neighbors.
- [ ] Type a word with letters the document's font does not include (try Cyrillic or an accented letter). It is set in the closest installed font and still looks like part of the text.
- [ ] Make a paragraph longer and shorter. Its lines wrap inside the paragraph; the paragraphs below keep their lines, and move down or up as a whole when the line count changes.
- [ ] A heading (one line) grows to the right when you type more into it.
- [ ] While typing, the editor sits exactly over the text it replaces. Esc and clicking away both keep what was typed. Emptying the text removes it.
- [ ] Scrolling while the editor is open commits the text. Say if that feels wrong.
- [ ] After each edit the page does not jump or flash noticeably. On a long document (100+ pages) an edit still feels immediate.
- [ ] Click a paragraph and drag it. Yellow guides appear when it lines up with other things or the middle of the page. Arrow keys nudge it; ⇧ makes bigger steps. Delete removes it.
- [ ] Format panel with text selected: change the font, the size and the color.
- [ ] Text tool (Aa): click an empty spot, type, click away. The Format panel sets the font, size and color of new text beforehand.
- [ ] Picture tool, and Edit ▸ Insert ▸ Picture…: the picture lands in the middle of what is in view, selected.
- [ ] Drag a picture file from the Finder onto a page: it lands where it was dropped. Drag a PDF onto a page: its pages are inserted after that page.
- [ ] ⌘V with a picture on the clipboard, and with text on the clipboard. ⌘C with a block of text selected copies its text.
- [ ] Select a picture: drag it, resize it by a corner (keeps proportions) and by a side (stretches), type a size in the Format panel, Replace…, Delete.
- [ ] A selected picture has small white square handles, as in Pages. Over a handle the pointer becomes the resize arrow that points the way the handle pulls, also on a turned picture and on a page that is itself rotated. It goes back to the arrow when it leaves the handle.
- [ ] Hold ⌘ over a picture's handle: the pointer becomes a curved arrow. Pressing and letting go of ⌘ without moving the mouse swaps the two pointers.
- [ ] ⌘-drag a handle: the picture turns about its center, the angle shows in a dark label by the pointer, and it catches lightly at 0°, 90°, 180° and 270°. With ⇧ as well it turns in steps of 45°. Compare the feel with Pages.
- [ ] A turned picture keeps its handles on its own corners; it can still be moved, resized along its own sides, nudged, replaced (the new one is turned the same way) and deleted. The Format panel shows its angle and takes a typed one.
- [ ] The rotate pointer was drawn for Sheaf. Check it looks at home next to the system's pointers, on light and dark pictures, and on a non-Retina display.
- [ ] The resize pointers also appear over the handles of a selected annotation (shapes, text boxes, stamps, signatures) and of a redaction mark.
- [ ] Select a paragraph while editing: a small square handle sits on its left and right side. Drag one: the box follows, and on letting go the same words are fitted to the new width, with the top line where it was. The pointer over a handle is the left-right resize arrow. Undo is "Resize Text".
- [ ] Double-click a paragraph to type in it: the editor has the same two handles. Drag a side while typing and the text wraps to the new width as you drag; typing continues, and clicking away keeps both the words and the width.
- [ ] Resizing only shows where a line can break differently. A heading or an address made wider looks the same afterwards, because a PDF stores no box, only where the letters are. Say if that is confusing.
- [ ] Open the document with your address block and double-click it: each line of the address is a line of its own in the editor, as on the page, not one run-on paragraph (changed 2026-10-04: blocks of short lines keep their line breaks). Check a few real documents for the opposite mistake too: a narrow column of running text, such as a caption or a sidebar, that now opens with a break at the end of every line.
- [ ] Right-click a picture while editing: Bring to Front, Send to Back, Align on Page ▸, Cut, Copy, Paste, Duplicate, Add Link…, Edit Mask, Reset Mask, Replace…, Flip Horizontally, Flip Vertically, Remove Background, Delete. Right-click text: Edit Text, then the same arranging and pasteboard items. Compare with the menu in Pages.

## Arranging, as in Pages (added 2026-10-04)

- [ ] Put two pictures so they overlap. Arrange ▸ Bring to Front (⇧⌘F), Send to Back (⇧⌘B), Bring Forward (⌥⇧⌘F), Send Backward (⌥⇧⌘B) change which covers which. The same four are buttons under Order in the Format panel and two of them are in the right-click menu. They are dimmed when nothing lies over or under the selection.
- [ ] Add a picture over a paragraph, then Send to Back: the text shows over the picture. Select the paragraph and try the same commands on it.
- [ ] On a real document with a white or colored page background, or a scan, Send to Back does not make the picture disappear behind it. Tell me about any file where a picture does vanish, or where the commands are dimmed although something clearly overlaps.
- [ ] On a busy page from a real document (clipped pictures, see-through ones), a restacked picture looks the same as before apart from the order, and everything else on the page is unchanged. Check in Preview and Acrobat after saving.
- [ ] Markup tools: overlapping shapes, stamps or signatures can be brought to the front and sent to the back from the right-click menu and the Arrange menu.
- [ ] Align on Page (Format panel, right-click, Arrange menu): Left, Center, Right, Top, Middle, Bottom put the selection against the page edge or in the middle, as Pages does with one thing selected.
- [ ] ⌘X, ⌘C, ⌘V on a selected picture and on a block of text. A copied picture pastes into Pages, Notes and Preview. ⌘D duplicates the selection; with nothing selected ⌘D is still Add Bookmark.
- [ ] A copy of a block of text appears below it, not on top. That is deliberate: text lying over text cannot be told apart afterwards. Say if you would rather have it elsewhere.
- [ ] Add Link… on a picture or text switches to the markup tools with a link over it selected and its target field in the Format panel. Say if the switch of tools feels wrong; Pages shows a popover instead.
- [ ] Flip Horizontally and Flip Vertically (Format panel, right-click, Arrange menu). After Flip Vertically the Angle field reads 180° more: a PDF cannot tell that apart from a mirrored picture turned half way.
- [ ] Opacity slider in the Format panel: the picture changes when the slider is let go. Check the result in Preview and Acrobat.
- [ ] Edit Mask (double-click a picture, Return with one selected, Format panel, right-click, Arrange menu): the whole picture shows faintly, the part that will show at full strength. Drag the handles and drag inside; Return or a click outside keeps it, Esc cancels. Reset Mask shows the whole picture again. A masked picture still moves, resizes and turns by what shows.
- [ ] While the mask is open, the old masked picture is hidden under a patch of the page's color, which also hides whatever lay under it until you finish. Say if that is distracting.
- [ ] Remove Background on a real photo of a person, an animal or an object: the background becomes see-through and the picture stays where it was. I could only try it on a made-up test picture. On a picture with no clear subject it says so.
- [ ] Constrain proportions off: a corner drag resizes freely, ⇧ keeps the shape, and typing a width leaves the height alone.
- [ ] Undo and Redo after each of the above, with sensible names in the Edit menu.
- [ ] In Russian: the Arrange menu, the right-click menu and the new Format panel rows read naturally and nothing is cut off.
- [ ] Each change is one Undo step with a sensible name.
- [ ] Text that is turned, or in a font whose letters cannot be told apart, is selectable but says why it cannot be changed.
- [ ] Save an edited file and open it in Preview, Chrome and Acrobat: it looks the same in all three, and Acrobat shows no font warnings.

## Find and replace (Phase 6)

- [ ] Edit ▸ Find ▸ Find and Replace… (⌥⌘F). Matches are tinted, the current one in orange; the arrows and Return step through them and scroll to them.
- [ ] Replace changes the current match and moves to the next. All replaces every match and says how many it could not change.
- [ ] The options menu at the left: Match Case, Whole Words, Regular Expression.
- [ ] A match that runs from the end of one line onto the next is found and replaced.

## Redaction (Phase 6)

- [ ] Redact tool: drag over text and over part of a picture. Marks are red frames one can see through. Select, move, resize and delete a mark.
- [ ] The wand menu: Email Addresses, Phone Numbers, Card Numbers, Social Security Numbers, and Search Results. Check on a document of your own that what it marks is right and nothing is missed.
- [ ] With text selected outside Edit mode, Tools ▸ Redact ▸ Mark Selected Text.
- [ ] The eye shows the marks as the black boxes they will become.
- [ ] Apply… asks first, then says what was removed. Afterwards the text cannot be selected, searched for or copied, in Sheaf or in Preview.
- [ ] Save the redacted file and try to recover the text: select all and copy in Preview, search in Acrobat, and run `strings` on the file. Nothing of it should be there.
- [ ] A picture partly under a mark keeps the rest of itself; the covered part is black and gone.
- [ ] Undo after Apply brings everything back, marks included. That is intended until the file is saved and closed.

## Recognizing text (Phase 6)

- [ ] Tools ▸ Recognize Text… on a scan and on a phone photo of a page. Afterwards text can be selected and copied, and Search finds words where they are in the picture.
- [ ] A document in Russian, and one that mixes languages.
- [ ] A long scan: the progress bar moves and Stop stops.
- [ ] The page looks exactly as before, on screen and printed.

## Comparing documents (Phase 7)

The Compare, Flows and export windows were built while the Mac's display was asleep, so
the automated checks covered what they compute but never saw them drawn. Look at these with extra care.

- [ ] File ▸ Compare Documents…: choose or drop an original and a revised PDF. Differences are tinted red on the left and green on the right, and listed in the sidebar.
- [ ] Tools ▸ Compare with… (⇧⌘K) from an open document, which becomes the original.
- [ ] Clicking a difference in the list, and ⌘↑ / ⌘↓, bring it into view on both sides with a frame around it.
- [ ] Scrolling and zooming one side moves the other. The toolbar switch turns that off.
- [ ] A page added or removed in the middle shows as one difference, and the pages after it still line up.
- [ ] Two versions that differ only in a picture or a moved line show "Looks different" with an orange frame.
- [ ] Swap Sides, and Export Report… (a PDF that lists every difference).
- [ ] A protected PDF asks for its password before it is compared.

## Converting (Phase 7)

- [ ] File ▸ Export To ▸ Word…: open the result in Word and in Pages. Paragraphs are paragraphs (not one per line), fonts, sizes, bold, italic and colors carry over, pictures are there, each page is the size of the PDF's.
- [ ] File ▸ Export To ▸ Excel… on an invoice or a statement: rows and columns land in cells, numbers are numbers (right-aligned, can be summed), each page is a sheet. Open in Excel and in Numbers.
- [ ] File ▸ Export To ▸ PDF/A…: the sheet lists what was done and what could not be. Save, then check the file with a validator such as veraPDF. Sheaf does not run one itself, so this is the only real test of conformance.
- [ ] A PDF that uses Helvetica, Times or Courier without including them: after PDF/A export the fonts are inside the file and the pages look the same.
- [ ] Tools ▸ Recognize Text…, Reduce File Size… and the exports still work on a 300-page document, with a progress bar that moves and a Stop that stops.

## Flows (Phase 7)

- [ ] File ▸ Flows…: four starter flows. Add, rename, reorder and remove flows; add, reorder (drag), change and remove steps.
- [ ] A step that exports to Word, Excel or images can only be last; the window says so otherwise.
- [ ] Run on Files… and dropping files on the window: asks for a folder, shows progress, Stop stops, the results are in the folder and the originals are untouched.
- [ ] "Join the Files into One Document First" with several files.
- [ ] Tools ▸ Run Flow ▸ a flow, on the open document: the document changes and one Undo takes it back. A flow that ends in an export asks where to save instead.
- [ ] Shortcuts app: "Run Flow on Files" lists the saved flows. Also "Recognize Text in PDF", "Make Word Document from PDF", "Make Excel Workbook from PDF", "Convert PDF to PDF/A".
- [ ] A shortcut made from "Run Flow on Files" with "Use as Quick Action" appears in Finder's Quick Actions.

## Polish (Phase 8)

- [ ] **Quit right after a change.** Rotate a page, press ⌘Q at once, reopen: the page is still rotated. Do the same right after Replace All, Recognize Text and running a flow finish. Changes that arrive from background work used not to be counted as unsaved until the next click or key press; that is fixed and checked in automated runs, but it is the one thing here that could lose work, so try it first.
- [ ] Russian: System Settings ▸ General ▸ Language & Region ▸ Applications ▸ add Sheaf with Русский. Go through the menus, each toolbar mode, the sheets and the Format panel. Look for English left over, text cut off in buttons, and wording a native speaker would not use.
- [ ] Russian plurals: "1 страница", "2 страницы", "5 страниц" in the page count, the redaction count and the Flows result.
- [ ] Help ▸ Sheaf Help opens the Help Book; its search finds "redact". The pages read well in light and dark.
- [ ] First launch on a fresh account: one tip at a time appears on the Edit, Organize Pages and Markup buttons, and goes away once the feature is used. Help ▸ Show Tips Again.
- [ ] VoiceOver: the toolbar and each tool row read sensibly. In Edit mode, Tab and ⇧Tab move through the page's text and pictures and each is announced.
- [ ] Full Keyboard Access on: every sheet can be worked and dismissed without the mouse.
- [ ] A 500-page document and a 200 MB one: opening, scrolling, searching, one edit, Organize Pages, and Reduce File Size all stay responsive. Edit ▸ Find ▸ Find and Replace with "All" on a long document shows a spinner and leaves the window usable.
- [ ] Memory in Activity Monitor after ten minutes of editing a large file stays reasonable (under about twice the file's size).

## Shipping (Phase 8)

- [ ] `Scripts/release.sh` with your Developer ID (see RELEASING.md). The signing and notarizing half of the script has never run.
- [ ] The disk image opens on another Mac with no Gatekeeper warning; the app runs from Applications.
- [ ] Sparkle: follow RELEASING.md to add it, then check that "Check for Updates…" appears under the Sheaf menu and finds a test update.
- [ ] The app's icon in the Dock, the Finder and the About window. It is drawn by `Scripts/make-icon.swift` (sheets of paper held by a band) as a first version; replace it if you want a designer's.

## On macOS 26

- [ ] Everything above. Sheaf is built for macOS 26 and later but has only ever run on macOS 27.
