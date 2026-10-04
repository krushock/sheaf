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
<li>To have PDFs open in Sheaf when you double-click them, choose it under <span class="menu">Default PDF app</span> in [[Sheaf > Settings…]]. Sheaf asks about this once, the first time it opens.</li>
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
<li>The percentage in the toolbar is a menu: pick a zoom level, <b>Fit Width</b> or <b>Fit Page</b>, or switch between continuous scrolling, one page and two pages.</li>
<li>Pinch, or use {{⌘+}} and {{⌘−}}. {{⌘0}} is actual size, {{⌘9}} fits the width, {{⌘8}} fits the whole page.</li>
</ul>
"""),
    ("markup", "Mark up and sign", "Highlight, comment, draw, stamp and sign.", """
<p>Click <span class="menu">Markup</span> in the toolbar, or press {{⇧⌘A}}, to show the markup tools.</p>
<h2>Mark text</h2>
<ul>
<li>Choose Highlight, Underline or Strikethrough, then drag across text. With text already selected, clicking the tool marks it at once.</li>
</ul>
<h2>Add notes, text and shapes</h2>
<ul>
<li><b>Note</b>: click where it should go and type in the Format panel.</li>
<li><b>Text</b>: drag out a box and type. Double-click it later to change the words.</li>
<li><b>Shapes and drawing</b>: drag to draw a rectangle, ellipse, line or arrow, or draw freehand.</li>
<li><b>Link</b>: drag a box, then give it a web address or a page in the Format panel.</li>
</ul>
<h2>Change what you added</h2>
<ul>
<li>Click to select, drag to move, drag a handle to resize. Arrow keys nudge; hold {{⇧}} for bigger steps. {{Delete}} removes.</li>
<li>The Format panel ({{⌥⌘I}}) sets color, line width, opacity, font and size.</li>
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
<p>Click <span class="menu">Edit</span> in the toolbar, or press {{⇧⌘E}}. A thin frame appears around every piece of text and every picture.</p>
<h2>Text</h2>
<ul>
<li><b>Change words</b>: double-click a paragraph and type. Click elsewhere or press {{Esc}} when done.</li>
<li><b>Move</b>: click once and drag. Yellow guides show when it lines up with other things. Arrow keys nudge.</li>
<li><b>Resize</b>: drag the handle on the left or right side of selected text, or of the editor while typing, to make its box narrower or wider. The words are fitted to the new width; the height follows from the lines.</li>
<li><b>Restyle</b>: with text selected, the Format panel changes its font, size and color.</li>
<li><b>Add</b>: choose the Text tool (Aa), click an empty spot and type.</li>
<li>{{Tab}} and {{⇧Tab}} move the selection from one piece of text to the next; {{Return}} starts typing in it.</li>
</ul>
<p>What you type uses the document's own font when it has the letters you need. When it does not, Sheaf uses the closest font installed on your Mac and puts it inside the file, so the result looks the same everywhere.</p>
<p>Short lines one under the other, such as an address, are kept as separate lines when you edit them. Long lines of running text are treated as a paragraph that wraps.</p>
<div class="note">A PDF has no flowing text the way a Pages document does. A paragraph re-wraps inside its own box; if it grows by a line, the paragraphs below it in the same block move down, but other things on the page stay where they are.</div>
<p>Some text can be selected and copied but not changed: text that is turned, text that is part of an element repeated across pages, and text in fonts whose letters cannot be identified reliably. The Format panel says so when you select it.</p>
<h2>Pictures</h2>
<ul>
<li>Click a picture to select it. Drag to move, drag a corner to resize in proportion, a side to stretch. Turn off <span class="menu">Constrain proportions</span> in the Format panel to resize a corner freely; {{⇧}} then keeps the shape.</li>
<li><b>Turn</b>: hold {{⌘}} and drag any of the picture's handles. The angle shows next to the pointer. Hold {{⇧}} as well to turn in steps of 45°, or type an angle in the Format panel.</li>
<li><b>Flip</b> it left to right or top to bottom with the buttons in the Format panel, or [[Arrange > Flip Horizontally]].</li>
<li><b>Mask</b>: double-click a picture, or choose <span class="menu">Edit Mask</span>, to pick the part of it that shows. Drag the handles, or drag inside to slide the part over the picture, then press {{Return}}. The whole picture stays in the file; <span class="menu">Reset Mask</span> shows all of it again.</li>
<li><b>Opacity</b>: the slider in the Format panel lets what is behind the picture show through.</li>
<li><b>Remove Background</b> keeps what the picture is of and makes the rest see-through. It works on photos with a clear subject.</li>
<li><b>Add</b>: the Picture tool, [[Edit > Insert > Picture…]], paste with {{⌘V}}, or drag a picture file onto the page.</li>
<li><b>Replace</b> and <b>Delete</b> are in the Format panel and the right-click menu.</li>
</ul>
<h2>Arranging text and pictures</h2>
<ul>
<li><b>In front and behind</b>: things on a page cover what was drawn before them. [[Arrange > Bring to Front]] {{⇧⌘F}}, [[Arrange > Send to Back]] {{⇧⌘B}}, and Bring Forward {{⌥⇧⌘F}} and Send Backward {{⌥⇧⌘B}} for one step, move the selection past what overlaps it. The same commands are in the Format panel and the right-click menu. They are dimmed when nothing lies over or under the selection.</li>
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
<li>Click <span class="menu">Edit</span> in the toolbar and choose the Redact tool (the solid rectangle).</li>
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
<li>Click <span class="menu">Form</span> in the toolbar, or press {{⇧⌘M}}. Choose a kind of field and drag it out on the page, or click once for the usual size.</li>
<li><b>Detect Fields</b> (the wand) makes fields from the boxes and lines printed on the page.</li>
<li>Select a field to rename it, set its look, or list a dropdown's options in the Format panel.</li>
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
    ("convert", "Convert and export", "Word, Excel, pictures and PDF/A.", """
<p>All of these are under [[File > Export To]] and [[File > Export as Images…]].</p>
<h2>Word <small>(Beta)</small></h2>
<p>Carries the text over in paragraphs with its fonts, sizes, colors and pictures, on pages of the same size. Columns, tables and exact positions are not carried over, so expect to tidy the result.</p>
<h2>Excel <small>(Beta)</small></h2>
<p>Each page becomes a sheet. Text that lines up in rows and columns lands in cells, and numbers become numbers you can add up. It works best on statements, invoices and price lists.</p>
<h2>PDF/A</h2>
<p>PDF/A-2b is a form of PDF meant to be readable decades from now. Sheaf puts fonts inside the file, adds a color profile and the required metadata, and removes scripts, attachments and the password. The sheet lists what was done and anything it could not put right.</p>
<div class="note">Sheaf does not certify the result. If the file is going to an archive that checks conformance, run it through their validator as well.</div>
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
<li><b>Watermark</b> and <b>Header and Footer</b> are in the [[Tools]] menu, with a live preview.</li>
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
<li>Sheaf's tools appear in the Shortcuts app as actions: merge, split, reduce, recognize text, convert, watermark, and "Run Flow on Files".</li>
<li>In Shortcuts, turn on "Use as Quick Action" for a shortcut to run it from the Finder's right-click menu.</li>
<li>The Finder's Services menu has "Merge with Sheaf", "Make PDF with Sheaf" and "Reduce File Size with Sheaf".</li>
</ul>
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
<li>{{⇧⌘A}} markup tools; {{⇧⌘E}} edit text and pictures; {{⇧⌘M}} form tools; {{⌥⌘O}} organize pages</li>
<li>{{⌥⌘I}} Format panel; {{⇧⌘K}} compare with another document</li>
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
