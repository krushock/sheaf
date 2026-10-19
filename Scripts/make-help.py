#!/usr/bin/env python3
"""Writes Sheaf's Help Book from the pages below.

    Scripts/make-help.py

The pages are plain HTML kept in this one file so they are easy to read through and
change together. Run it after changing anything here; the result is in
Sheaf/Resources/Sheaf.help and is copied into the app when it is built.
"""
import html
import os
import subprocess

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
book = os.path.join(root, "Sheaf/Resources/Sheaf.help/Contents")
pages_dir = os.path.join(book, "Resources/en.lproj")
os.makedirs(pages_dir, exist_ok=True)

STYLE = """
:root { color-scheme: light dark; }
body { font: 14px/1.55 -apple-system, sans-serif; margin: 0; padding: 28px 36px 48px; max-width: 720px; color: #1d1d1f; background: #fff; }
h1 { font-size: 26px; font-weight: 700; margin: 0 0 6px; }
h2 { font-size: 17px; margin: 28px 0 6px; }
p.lead { font-size: 15px; color: #555; margin-top: 0; }
ul, ol { padding-left: 22px; }
li { margin: 4px 0; }
a { color: #0a66d8; text-decoration: none; }
a:hover { text-decoration: underline; }
kbd { font: 12px -apple-system, sans-serif; border: 1px solid #c8c8cc; border-radius: 5px; padding: 1px 5px; background: #f5f5f7; white-space: nowrap; }
.menu { font-weight: 600; white-space: nowrap; }
nav { font-size: 13px; margin-bottom: 18px; }
.topics { list-style: none; padding: 0; display: grid; grid-template-columns: 1fr 1fr; gap: 10px 24px; }
.topics li { margin: 0; }
.topics a { font-weight: 600; }
.topics span { display: block; color: #666; font-size: 13px; }
.note { border-left: 3px solid #0a66d8; padding: 2px 12px; color: #444; margin: 14px 0; }
@media (prefers-color-scheme: dark) {
  body { color: #f2f2f7; background: #1e1e1e; }
  p.lead, .topics span { color: #a1a1a6; }
  a { color: #4c9aff; }
  kbd { background: #2c2c2e; border-color: #48484a; }
  .note { color: #c7c7cc; border-color: #4c9aff; }
}
"""

# Each page: file name, title, one-line summary, body. In the body, [[Menu > Item]] is a
# menu path and {{keys}} a keyboard shortcut.
PAGES = [
    ("view", "Read a document", "Open, move around, search and zoom.", """
<h2>Open</h2>
<ul>
<li>Double-click a PDF or picture in the Welcome window, drag one onto Sheaf's icon, or choose [[File > Open…]] {{⌘O}}.</li>
<li>Pictures open as one-page documents. A protected PDF asks for its password.</li>
<li>A PDF opened from a message in Mail can be sent back: [[File > Reply to Sender…]] opens a reply in Mail with the PDF attached and the earlier message quoted. Sheaf also offers this when you save or close such a PDF after changing it. It asks Mail which message the PDF came with, so macOS asks once whether Sheaf may control Mail, and the message has to be still selected there.</li>
<li>To have PDFs or pictures open in Sheaf when you double-click them, choose it under <span class="menu">Default Apps</span> in [[Sheaf > Settings…]] ▸ General: for PDF documents, for all pictures at once, or for each kind of picture. Sheaf asks about PDFs once, the first time it opens.</li>
</ul>
<h2>Move around</h2>
<ul>
<li>The sidebar shows thumbnails, the table of contents, or highlights and notes. Switch with the button at the left of the toolbar, or {{⌥⌘2}}, {{⌥⌘3}}, {{⌥⌘4}}. {{⌥⌘1}} hides it.</li>
<li>[[Go > Go to Page…]] {{⌥⌘G}} jumps to a page by number. {{⌘[}} and {{⌘]}} go back and forward through where you have been.</li>
<li>[[View]] switches between continuous scrolling {{⌘1}}, one page {{⌘2}} and two pages {{⌘3}}.</li>
</ul>
<h2>Search</h2>
<ul>
<li>{{⌘F}} puts the cursor in the search field. Results are listed in the sidebar; {{⌘G}} and {{⇧⌘G}} step through them.</li>
<li>A scanned document has no text to search until you <a href="recognize.html">recognize its text</a>.</li>
</ul>
<h2>Zoom</h2>
<ul>
<li>The zoom floats at the foot of the tools: <b>+</b> and <b>−</b>, and the percentage between them is a menu with zoom levels, <b>Fit Width</b> and <b>Fit Page</b>. The View menu switches between continuous scrolling, one page and two pages.</li>
<li>Pinch, or use {{⌘+}} and {{⌘−}}. {{⌘0}} is actual size, {{⌘9}} fits the width, {{⌘8}} fits the whole page.</li>
</ul>
"""),
    ("markup", "Mark up and sign", "Highlight, comment, draw, stamp and sign.", """
<p>The tools are in the strip at the side of the pages. Click one to take it up; its options open in the panel beside the strip. Click the tool again, or the arrow at the top of the strip, to hide them. Hold the pointer over a tool to see its name. To have the strip on the other side, drag the dots at its top across the window. {{⇧⌘A}} takes the Select tool.</p>
<h2>Mark text</h2>
<ul>
<li>Choose Highlight, Underline or Strikethrough, then drag across text. With text already selected, clicking the tool marks it at once.</li>
</ul>
<h2>Add notes, text and shapes</h2>
<ul>
<li><b>Note</b>: click where it should go and type in the options panel.</li>
<li><b>Text</b>: drag out a box and type. Double-click it later to change the words.</li>
<li><b>Shapes and drawing</b>: drag to draw a rectangle, ellipse, line or arrow, or draw freehand.</li>
<li><b>Link</b>: drag a box, then give it a web address or a page in the options panel.</li>
</ul>
<h2>Change what you added</h2>
<ul>
<li>Click to select, drag to move, drag a handle to resize. Arrow keys nudge; hold {{⇧}} for bigger steps. {{Delete}} removes.</li>
<li>The panel beside the tools ({{⌃⌘I}}) sets color, line width, opacity, font and size: for the tool in hand, or, with something selected, for that.</li>
</ul>
<h2>Sign</h2>
<ul>
<li>Click <span class="menu">Sign</span>. Draw a signature with the trackpad, type one, or use a photo of one on white paper. Saved signatures stay in the list.</li>
<li>This places a picture of your signature. It is not a certificate-based digital signature.</li>
</ul>
<h2>Make marks permanent</h2>
<ul><li>[[Tools > Flatten Annotations…]] makes highlights, notes, drawings and stamps part of the pages.</li></ul>
"""),
    ("pages", "Arrange pages", "Reorder, rotate, add, remove and split pages.", """
<p>Click <span class="menu">Organize Pages</span> in the toolbar, or press {{⌥⌘O}}, to see every page in a grid.</p>
<ul>
<li>Drag pages to reorder them. Select several with {{⇧}}-click, {{⌘}}-click or by dragging a box around them.</li>
<li>Drag PDFs and pictures in from the Finder to add them where you drop them. Drag pages out to the Finder to make a new PDF from them.</li>
<li>{{⌘L}} and {{⌘R}} rotate. {{Delete}} removes. Cut, Copy and Paste work between Sheaf windows.</li>
<li>[[Edit > Insert]] adds a blank page, pages from a file, or pages from a scanner. A blank page can be the size of any page the document has, a common paper such as A4, A3 or US Letter, or, with <span class="menu">Other Size…</span>, any size either way up.</li>
<li>[[Tools > Pages > Split Down the Middle]] cuts each selected page in two, for scans of open books.</li>
</ul>
<div class="note">Removing a page also removes the bookmarks and links that pointed to it.</div>
"""),
    ("edit", "Change text and pictures", "Edit what is on the page as you would in Pages.", """
<p>Take the editing tool (the second in the strip at the side of the pages), or press {{⇧⌘E}}. A thin frame appears around every piece of text and every picture.</p>
<h2>Text</h2>
<ul>
<li><b>Change words</b>: double-click a paragraph and type. Click elsewhere or press {{Esc}} when done.</li>
<li><b>Move</b>: click once and drag. Yellow guides show when it lines up with other things. Arrow keys nudge.</li>
<li><b>Resize</b>: drag the handle on the left or right side of selected text, or of the editor while typing, to make its box narrower or wider. The words are fitted to the new width; the height follows from the lines.</li>
<li><b>Restyle</b>: with text selected, the options panel changes its font, size and color, makes it bold or italic, and under Paragraph sets its alignment (left, centered, right or justified), its line spacing and the space before each paragraph. A single line, such as a heading, is centered or set to the right within the page's column of text.</li>
<li><b>Add</b>: choose the Text tool (Aa), click an empty spot and type.</li>
<li>{{Tab}} and {{⇧Tab}} move the selection from one piece of text to the next; {{Return}} starts typing in it.</li>
</ul>
<p>What you type uses the document's own font when it has the letters you need. When it does not, Sheaf uses the closest font installed on your Mac and puts it inside the file, so the result looks the same everywhere.</p>
<p>Short lines one under the other, such as an address, are kept as separate lines when you edit them. Long lines of running text are treated as a paragraph that wraps.</p>
<div class="note">A PDF has no flowing text the way a Pages document does. A paragraph re-wraps inside its own box; if it grows by a line, the paragraphs below it in the same block move down, but other things on the page stay where they are.</div>
<p>Some text can be selected and copied but not changed: text that is turned, text that is part of an element repeated across pages, and text in fonts whose letters cannot be identified reliably. The options panel says so when you select it.</p>
<h2>Pictures</h2>
<ul>
<li>Click a picture to select it. Drag to move, drag a corner to resize in proportion, a side to stretch. Turn off <span class="menu">Constrain proportions</span> in the options panel to resize a corner freely; {{⇧}} then keeps the shape.</li>
<li><b>Turn</b>: hold {{⌘}} and drag any of the picture's handles. The angle shows next to the pointer. Hold {{⇧}} as well to turn in steps of 45°. In the options panel, drag the Rotate knob, type an angle, or click Rotate Left or Rotate Right for a quarter turn; those two are also in the right-click menu and the Arrange menu.</li>
<li><b>Flip</b> it left to right or top to bottom with the buttons in the options panel, or [[Arrange > Flip Horizontally]].</li>
<li><b>Mask</b>: double-click a picture, or choose <span class="menu">Edit Mask</span>, to pick the part of it that shows. Drag the handles, or drag inside to slide the part over the picture, then press {{Return}}. The whole picture stays in the file; <span class="menu">Reset Mask</span> shows all of it again.</li>
<li><b>Opacity</b>: the slider in the options panel lets what is behind the picture show through.</li>
<li><b>Adjustments</b>, in the options panel as in Pages: Exposure, Saturation and Enhance, and under More Adjustments Contrast, Highlights, Shadows, Sharpness, Temperature and Tint. Each change starts from the picture as it was when you selected it, so you can go back and forth; Reset Adjustments returns to it, and Undo takes back each change.</li>
<li><b>Remove Background</b> keeps what the picture is of and makes the rest see-through. It works on photos with a clear subject.</li>
<li><b>Auto Crop</b> masks the picture down to the part that matters. It is a mask like any other, so <span class="menu">Edit Mask</span> and <span class="menu">Reset Mask</span> work on it.</li>
<li><b>Super Resolution</b> gives a small or blurry picture four times the pixels and sharpens it, in the same place on the page. See <a href="intelligence.html">Apple Intelligence</a>.</li>
<li><b>Add</b>: the Picture tool, [[Edit > Insert > Picture…]], paste with {{⌘V}}, or drag a picture file onto the page. [[Edit > Insert > Image Playground…]] makes a new one from a description.</li>
<li><b>Replace</b> and <b>Delete</b> are in the options panel and the right-click menu.</li>
</ul>
<h2>Arranging text and pictures</h2>
<ul>
<li><b>In front and behind</b>: things on a page cover what was drawn before them. [[Arrange > Bring to Front]] {{⇧⌘F}}, [[Arrange > Send to Back]] {{⇧⌘B}}, and Bring Forward {{⌥⇧⌘F}} and Send Backward {{⌥⇧⌘B}} for one step, move the selection past what overlaps it. The same commands are in the options panel and the right-click menu. They are dimmed when nothing lies over or under the selection.</li>
<li><b>Align on Page</b> lines the selection up with an edge or the middle of the page.</li>
<li><b>Cut</b>, <b>Copy</b> and <b>Paste</b> work on a selected picture or block of text. <b>Duplicate</b> {{⌘D}} makes a copy next to it; a copied picture uses the same image, so the file hardly grows.</li>
<li><b>Add Link…</b> puts a link over the selection and opens the markup tools, where you set where it goes.</li>
</ul>
<div class="note">A PDF page has no layers. Nothing is sent behind something that covers the whole page, such as a background or a scan, because it would disappear. Annotations always lie over the page itself; among themselves they can be brought to the front and sent to the back in the markup tools.</div>
<h2>Find and replace</h2>
<ul><li>[[Edit > Find > Find and Replace…]] {{⌥⌘F}}. The menu at the left of the bar has Match Case, Whole Words and Regular Expression.</li></ul>
"""),
    ("redact", "Remove information for good", "Redaction takes text and pictures out of the file, not just out of sight.", """
<p>Covering something with a black rectangle leaves it in the file, where anyone can copy it out. Redaction removes it.</p>
<ol>
<li>Take the Redact tool (the solid rectangle) in the strip at the side of the pages.</li>
<li>Drag over what should go. Each mark is a red frame you can still see through, move, resize and delete.</li>
<li>To mark every email address, phone number, card number or search result at once, use the wand menu.</li>
<li>Click the eye to see the page as it will look.</li>
<li>Click <span class="menu">Apply…</span>. Text, pictures and drawings under the marks are removed and black boxes are drawn in their place.</li>
<li>Save.</li>
</ol>
<div class="note">Undo still brings the content back until you close the document. Copies of the file made before, and versions macOS keeps under [[File > Revert To]], still hold the original. Send the saved file, or a duplicate of it, not an older copy.</div>
<p>On a scanned page, a mark removes the part of the picture underneath it.</p>
"""),
    ("recognize", "Make scans searchable", "Recognize the text in scanned pages and photos.", """
<p>A scan is a picture of a page. [[Tools > Recognize Text…]] reads the writing in it and lays the words over the picture invisibly, so you can search, select and copy.</p>
<ul>
<li>Recognition happens on your Mac. Nothing is sent anywhere.</li>
<li>The page looks exactly as before, on screen and in print.</li>
<li>Pages that already have text are skipped.</li>
</ul>
"""),
    ("forms", "Fill in and build forms", "Fill fields, or add them to a form that has none.", """
<h2>Fill in</h2>
<ul>
<li>Click a field and type. {{Tab}} and {{⇧Tab}} move between fields. Click checkboxes and choices to switch them.</li>
<li>Date fields show a calendar. Signature fields show your saved signatures.</li>
<li>[[Tools > Form > Highlight Fields]] tints the fields so they are easy to find.</li>
</ul>
<h2>Build</h2>
<ul>
<li>Take the Form fields tool in the strip at the side of the pages, or press {{⇧⌘M}}. Choose a kind of field in the panel beside it and drag it out on the page, or click once for the usual size.</li>
<li><b>Detect Fields</b> (the wand) makes fields from the boxes and lines printed on the page.</li>
<li>Select a field to rename it, set its look, or list a dropdown's options in the options panel.</li>
</ul>
<h2>Finish</h2>
<ul>
<li>[[Tools > Form > Flatten Form…]] makes what is filled in part of the pages, so it can no longer be changed.</li>
<li>[[Tools > Form > Reset Form…]] empties every field.</li>
</ul>
"""),
    ("compare", "Compare two versions", "See what changed between two documents.", """
<p>[[File > Compare Documents…]], or [[Tools > Compare with…]] {{⇧⌘K}} from an open document.</p>
<ul>
<li>The original is on the left and the revised version on the right. Removed words are tinted red, added words green. An orange frame marks a place that looks different though its words are the same, such as a changed picture.</li>
<li>The sidebar lists every difference. Click one, or press {{⌘↓}} and {{⌘↑}}, to go to it on both sides.</li>
<li>The two sides scroll and zoom together. A page added or removed in the middle does not throw off the pages after it.</li>
<li><span class="menu">Export Report…</span> saves the list of differences as a PDF.</li>
</ul>
"""),
    ("convert", "Convert and export", "Word, Excel, rich text, web pages, pictures and PDF/A.", """
<p>All of these are under [[File > Export To]] and [[File > Export as Images…]].</p>
<h2>Word <small>(Beta)</small></h2>
<p>Carries the text over in paragraphs with its fonts, sizes, colors and pictures, on pages of the same size. Columns, tables and exact positions are not carried over, so expect to tidy the result.</p>
<h2>Excel <small>(Beta)</small></h2>
<p>Each page becomes a sheet. Text that lines up in rows and columns lands in cells, and numbers become numbers you can add up. It works best on statements, invoices and price lists.</p>
<h2>PDF/A</h2>
<p>PDF/A-2b is a form of PDF meant to be readable decades from now. Sheaf puts fonts inside the file, adds a color profile and the required metadata, and removes scripts, attachments and the password. The sheet lists what was done and anything it could not put right.</p>
<div class="note">Sheaf does not certify the result. If the file is going to an archive that checks conformance, run it through their validator as well.</div>
<h2>Rich Text, Web Page and Plain Text <small>(Beta)</small></h2>
<p>The text in paragraphs, as for Word, saved as an RTF file for TextEdit and Pages, as a web page, or as plain words. Pictures are left out.</p>
<h2>Pictures</h2>
<p>[[File > Export as Images…]] saves pages as PNG, JPEG, TIFF or HEIC at the resolution you choose.</p>
"""),
    ("files", "Whole-document tools", "Merge, split, shrink, protect, watermark and number.", """
<ul>
<li><b>Merge</b>: [[File > New from PDFs…]] {{⌥⌘N}} joins PDFs and pictures in the order you list them.</li>
<li><b>From pictures</b>: [[File > New from Images…]] {{⇧⌘N}} makes a page from each picture, and can square up photos of paper.</li>
<li><b>Split</b>: [[File > Split into Documents…]] by page count, page ranges or bookmarks.</li>
<li><b>Shrink</b>: [[File > Reduce File Size…]]. "Keep Everything Exact" only repacks; the other choices also scale down pictures.</li>
<li><b>Protect</b>: [[File > Set Password…]] encrypts with AES 256-bit. A forgotten password cannot be recovered.</li>
<li><b>All at once, while saving</b>: [[File > Save As…]] and [[File > Export…]] have the same choices under the file's name, as Preview does: <span class="menu">Create PDF/A</span>, <span class="menu">Optimize images for screen</span>, <span class="menu">Save images as JPEG</span> and <span class="menu">Permissions…</span>. Save As makes the document in the window what was saved; Export writes a copy and leaves the document alone. Export can also write the page being read as a JPEG, PNG, TIFF or HEIC picture.</li>
<li><b>Watermark</b>, <b>Header and Footer</b>, <b>Bates Numbering</b>, <b>Background</b> and <b>Crop Pages</b> are in the [[Tools]] menu and the Document Tools menu in the toolbar, with a live preview. Bates numbers count the pages they are added to, with the text before and after the number and the number of digits you choose. Crop Pages hides the edges of pages without deleting anything; <span class="menu">Remove White Margins</span> crops to what is on the page, and <span class="menu">Show Whole Pages</span> brings the edges back.</li>
<li><b>Remove Hidden Information</b>: [[Tools > Remove Hidden Information…]] lists what the document carries besides its pages (metadata, attached files, scripts and actions, comments, bookmarks, and data other apps left in it) and takes out what you choose. The document is written out afresh, so what is removed is gone from the file. Do this before sending a document outside your organization; for text on the pages, use <a href="redact.html">redaction</a>.</li>
<li><b>Read Out Loud</b>: [[View > Read Out Loud]] reads the document aloud from the page you are on, in your Mac's voice for the document's language, and turns the pages as it goes. Choose it again to stop.</li>
<li><b>Details</b>: [[File > Document Info…]] {{⌘I}} shows and changes the title, author and keywords.</li>
</ul>
"""),
    ("flows", "Automate with Flows and Shortcuts", "Run the same steps on many files.", """
<h2>Flows</h2>
<p>A flow is a saved list of steps, such as "recognize text, then reduce the file size". [[File > Flows…]] opens the list.</p>
<ul>
<li>Add steps with <span class="menu">Add Step</span>, drag to reorder, and set each step's options on its row.</li>
<li><span class="menu">Run on Files…</span>, or drop files on the window, runs the flow on each and saves the results in a folder you choose. The originals are not changed.</li>
<li>[[Tools > Run Flow]] runs a flow on the open document. One Undo takes it back.</li>
</ul>
<h2>Shortcuts and Quick Actions</h2>
<ul>
<li>Sheaf's tools appear in the Shortcuts app as actions: merge, split, reduce, recognize text, convert, watermark, "Summarize PDF" and "Run Flow on Files".</li>
<li>In Shortcuts, turn on "Use as Quick Action" for a shortcut to run it from the Finder's right-click menu.</li>
<li>The Finder's Services menu has "Merge with Sheaf", "Make PDF with Sheaf" and "Reduce File Size with Sheaf".</li>
</ul>
"""),
    ("intelligence", "Apple Intelligence", "Summaries, answers, Writing Tools and smarter pictures, on this Mac.", """
<p>On a Mac with Apple Intelligence turned on, Sheaf uses the models that are part of macOS. They run on your Mac: Sheaf sends your documents nowhere. Writing Tools and Image Playground are Apple's own and follow the choices you made for them in System Settings.</p>
<h2>Summary and key points</h2>
<ul>
<li>Click <span class="menu">Summary</span> in the toolbar, or choose [[Tools > Summarize]], to open the Summary panel on the right. {{⌃⌘U}} shows and hides it.</li>
<li><span class="menu">Summary</span> says in a few sentences what the document is about. <span class="menu">Key Points</span> lists what matters most.</li>
<li>The menu at the bottom chooses what is summed up: the whole document, the page you are reading, or the text you selected.</li>
<li>A long document is read a part at a time, which takes a while: a few minutes for a hundred pages of dense text. The panel shows how far it has come, and <span class="menu">Stop</span> ends it.</li>
<li>Copy the result, or put it on the page as a note with <span class="menu">Add as Note</span>.</li>
</ul>
<h2>Ask about the document</h2>
<ul>
<li>In the Summary panel, click <span class="menu">Ask</span> and type a question, such as "When does the lease end?".</li>
<li>The answer comes from the document's text. The pages it is from are named under it: click one to go there.</li>
<li>When the document does not seem to say, the answer says so rather than guessing.</li>
</ul>
<div class="note">The model on your Mac is small. It can misread a figure, miss a passage or leave something out, more so in long documents and in languages other than the main ones it knows. Check what matters against the pages. A scanned document has to have its <a href="recognize.html">text recognized</a> before it can be read.</div>
<h2>Writing Tools</h2>
<ul>
<li>While you <a href="edit.html">edit text</a> on a page, or type in a note or text box, [[Edit > Writing Tools]] and the right-click menu proofread and rewrite it, as in Pages.</li>
<li>With text selected on a page that you are not editing, Writing Tools can summarize it or list its key points in a panel of its own.</li>
</ul>
<h2>Pictures</h2>
<ul>
<li><b>Image Playground</b>: [[Edit > Insert > Image Playground…]] makes a picture and puts it on the page. Selected text is offered as what the picture is about, and a selected picture as what to make it from.</li>
<li><b>Super Resolution</b>, in the options panel for a selected picture, gives it four times the pixels and sharpens it. It is for pictures up to 1920 pixels on a side without see-through parts. The first time, macOS may ask to download what it needs from Apple.</li>
<li><b>Auto Crop</b> finds the part of a picture the eye goes to and masks the rest.</li>
<li><b>Remove Background</b> keeps the subject of a photo and makes the rest see-through.</li>
<li><b>Describe</b> says in a sentence or two what a picture shows. Copy the description or add it to the page as a note.</li>
</ul>
<h2>Title and keywords</h2>
<p>In [[File > Document Info…]], <span class="menu">Suggest</span> fills in the title, subject and keywords that are empty, from how the document starts. Nothing is saved until you click Save.</p>
"""),
    ("privacy", "Sheaf and your privacy", "What stays on your Mac, and the few things that leave it.", """
<p>Sheaf has no account, no server, no ads and no analytics, and sends no crash reports. It is not allowed to connect to the internet at all: macOS keeps it in a sandbox without network access. Your documents are opened, changed and saved on your Mac, in the places you choose.</p>
<h2>What Sheaf keeps on your Mac</h2>
<ul>
<li><b>Signatures</b> you save, encrypted, with the key in your Keychain.</li>
<li><b>Flows</b> you make, and your settings.</li>
<li>macOS keeps the list of recent documents and the versions of each document, as for any app.</li>
</ul>
<h2>Your name in the PDFs you mark up</h2>
<p>Notes, highlights, drawings and signatures you add carry your name as their author, as in other PDF apps, and anyone you send the PDF to can see it. Change the name, or leave it empty to add none, in [[Sheaf > Settings…]] ▸ General ▸ <span class="menu">Name on notes and markup</span>. Document Info shows the document's own author, which is separate.</p>
<h2>Apple Intelligence</h2>
<ul>
<li>Summaries, answers, picture descriptions, Auto Crop, Remove Background and Super Resolution run on your Mac. The model for Super Resolution is downloaded from Apple once, after you agree.</li>
<li>Writing Tools and Image Playground are Apple's, and follow what you chose for Apple Intelligence in System Settings. Depending on those choices, Writing Tools can use Apple's Private Cloud Compute, or ChatGPT if you turned that on.</li>
<li>What Apple Intelligence writes is marked as such: a note made from a summary or a description says so and is signed "Apple Intelligence", and a picture from Image Playground carries the standard metadata for pictures made by a generative model.</li>
</ul>
<h2>Mail</h2>
<p>When you reply to a PDF that came from Mail, Sheaf asks Mail, with the permission macOS asked you for, for the message the PDF came with, so that the reply quotes it. The draft and the copy of the PDF made for Mail are removed a few minutes later. Nothing is sent until you send it in Mail.</p>
"""),
    ("keys", "Keyboard shortcuts", "The keys worth knowing.", """
<h2>Everywhere</h2>
<ul>
<li>{{⌘F}} search, {{⌘G}} next result, {{⇧⌘G}} previous result</li>
<li>{{⌥⌘F}} find and replace</li>
<li>{{⌘1}} {{⌘2}} {{⌘3}} page layout; {{⌘0}} actual size; {{⌘9}} fit width; {{⌘8}} fit page; {{⌘+}} {{⌘−}} zoom</li>
<li>{{⌥⌘1}} hide sidebar; {{⌥⌘2}} thumbnails; {{⌥⌘3}} table of contents; {{⌥⌘4}} highlights and notes</li>
<li>{{⌥↑}} {{⌥↓}} previous and next page; {{⌥⌘G}} go to page</li>
<li>{{⌘L}} {{⌘R}} rotate; {{⌘D}} add bookmark; {{⌘I}} document info</li>
</ul>
<h2>Modes</h2>
<ul>
<li>{{⇧⌘A}} Select tool; {{⇧⌘E}} edit text and pictures; {{⇧⌘M}} form fields; {{⌥⌘O}} organize pages</li>
<li>{{⌃⌘I}} options panel; {{⌃⌘U}} Summary panel; {{⇧⌘K}} compare with another document</li>
</ul>
<h2>With something selected</h2>
<ul>
<li>Arrow keys nudge; {{⇧}} with arrows for bigger steps</li>
<li>{{Return}} edits text; {{Esc}} finishes or deselects; {{Delete}} removes</li>
<li>{{Tab}} and {{⇧Tab}} move to the next and previous field or piece of text</li>
</ul>
<h2>Markup tools</h2>
<ul><li>{{⌃⌘H}} highlight, {{⌃⌘U}} underline, {{⌃⌘S}} strikethrough, {{⌃⌘T}} text, {{⌃⌘N}} note, {{⌃⌘R}} rectangle, {{⌃⌘O}} ellipse, {{⌃⌘A}} arrow, {{⌃⌘D}} draw, {{⌃⌘K}} link</li></ul>
"""),
]


def render(body):
    import re
    body = re.sub(r"\[\[(.+?)\]\]", lambda m: '<span class="menu">' + html.escape(m.group(1)).replace("&gt;", "▸") + "</span>", body)
    body = re.sub(r"\{\{(.+?)\}\}", lambda m: "<kbd>" + html.escape(m.group(1)) + "</kbd>", body)
    return body


def page(title, summary, body, name):
    keywords = html.escape(title + ", " + summary)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(summary)}">
<meta name="keywords" content="{keywords}">
<meta name="robots" content="index, anchors">
<link rel="stylesheet" href="style.css">
</head>
<body>
<a name="{name}"></a>
<nav><a href="index.html">Sheaf Help</a></nav>
<h1>{html.escape(title)}</h1>
<p class="lead">{html.escape(summary)}</p>
{render(body)}
</body>
</html>
"""


with open(os.path.join(pages_dir, "style.css"), "w", encoding="utf-8") as file:
    file.write(STYLE)

topics = "\n".join(f'<li><a href="{name}.html">{html.escape(title)}</a><span>{html.escape(summary)}</span></li>' for name, title, summary, _ in PAGES)
index = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Sheaf Help</title>
<meta name="AppleTitle" content="Sheaf Help">
<meta name="description" content="How to read, mark up, change and convert PDFs with Sheaf.">
<meta name="robots" content="index, anchors">
<link rel="stylesheet" href="style.css">
</head>
<body>
<a name="index"></a>
<h1>Sheaf Help</h1>
<p class="lead">Sheaf reads, marks up and changes PDFs. Everything happens on your Mac, and nothing is saved until you save.</p>
<ul class="topics">
{topics}
</ul>
<h2>Good to know</h2>
<ul>
<li>Every change can be undone with <kbd>⌘Z</kbd>, including changes to pages and whole-document tools.</li>
<li>Sheaf saves the way Pages does: there is no need to save as you go, and <span class="menu">File ▸ Revert To</span> brings back earlier versions.</li>
<li>Most changes are added to the end of the file, which keeps saving fast and leaves a digitally signed file's signature intact. Redaction, reducing the file size and setting a password write the file out afresh.</li>
</ul>
</body>
</html>
"""
with open(os.path.join(pages_dir, "index.html"), "w", encoding="utf-8") as file:
    file.write(index)
for name, title, summary, body in PAGES:
    with open(os.path.join(pages_dir, f"{name}.html"), "w", encoding="utf-8") as file:
        file.write(page(title, summary, body, name))

info = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>com.valeryburtsev.Sheaf.help</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Sheaf Help</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSignature</key>
	<string>hbwr</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>HPDBookAccessPath</key>
	<string>index.html</string>
	<key>HPDBookIndexPath</key>
	<string>search.helpindex</string>
	<key>HPDBookTitle</key>
	<string>Sheaf Help</string>
	<key>HPDBookType</key>
	<string>3</string>
</dict>
</plist>
"""
with open(os.path.join(book, "Info.plist"), "w", encoding="utf-8") as file:
    file.write(info)

# The index Help Viewer searches. Left out without complaint where the tool is missing.
try:
    subprocess.run(["hiutil", "-I", "corespotlight", "-Caf", os.path.join(pages_dir, "search.cshelpindex"), pages_dir], check=True, capture_output=True)
    subprocess.run(["hiutil", "-I", "lsm", "-Caf", os.path.join(pages_dir, "search.helpindex"), pages_dir], check=True, capture_output=True)
except (OSError, subprocess.CalledProcessError) as error:
    print(f"The search index was not made: {error}")
print(f"Wrote {len(PAGES) + 1} pages to {pages_dir}")
