#!/usr/bin/env python3
"""Brings the string catalog up to date and fills in the translations.

Run after `make build`, which leaves the strings found in the code in the build folder:

    Scripts/localize.py

It adds new strings to Sheaf/Resources/Localizable.xcstrings, drops ones the code no
longer has, writes the Russian from Scripts/translations/, and lists what still needs
translating. English strings that count things get singular and plural forms.
"""
import glob
import importlib.util
import json
import os
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
catalog_path = os.path.join(root, "Sheaf/Resources/Localizable.xcstrings")

# What the last build found in the code.
found = glob.glob(os.path.join(root, "build/Build/Intermediates.noindex/Sheaf.build/**/*.stringsdata"), recursive=True)
if found:
    subprocess.run(["xcrun", "xcstringstool", "sync", catalog_path, "--stringsdata", *found], check=True)
else:
    print("No build output found; run `make build` first. Using the catalog as it is.", file=sys.stderr)

russian = {}
for path in sorted(glob.glob(os.path.join(root, "Scripts/translations/ru_*.py"))):
    spec = importlib.util.spec_from_file_location("ru", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    russian.update(module.RU)

# English strings that count one thing: the form to show for exactly one.
singular = {
    "%lld annotations": "%lld annotation",
    "%lld characters": "%lld character",
    "%lld differences": "%lld difference",
    "%lld documents": "%lld document",
    "%lld fields were added to this page.": "%lld field was added to this page.",
    "%lld files saved": "%lld file saved",
    "%lld pages": "%lld page",
    "%lld pages added.": "%lld page added.",
    "%lld results": "%lld result",
    "%lld shapes": "%lld shape",
    "%lld Pages in Each Document": "%lld Page in Each Document",
    "%lld annotations are of kinds the standard does not allow (sound, video, 3D, attachments)": "%lld annotation is of a kind the standard does not allow (sound, video, 3D, attachments)",
    "%lld annotations have no stored picture of themselves": "%lld annotation has no stored picture of itself",
    "%lld pages have no text to select. Their writing is read on this Mac and laid over them invisibly, so the pages look the same but can be searched and copied from.": "%lld page has no text to select. Its writing is read on this Mac and laid over it invisibly, so the page looks the same but can be searched and copied from.",
    "%lld pages use printing-ink colors (CMYK), which need a press profile": "%lld page uses printing-ink colors (CMYK), which need a press profile",
    "Choose where to save the %lld documents.": "Choose where to save the %lld document.",
    "Choose where to save the %lld pictures.": "Choose where to save the %lld picture.",
    "Removed %lld attached files": "Removed %lld attached file",
    "Removed %lld scripts and actions": "Removed %lld script or action",
    "Repacked %lld parts that used an old compression": "Repacked %lld part that used an old compression",
    "Set %lld annotations to show and print": "Set %lld annotation to show and print",
    "Text Recognized on %lld Pages": "Text Recognized on %lld Page",
    "parts of %lld pictures": "part of %lld picture",
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(forms):
    return {"variations": {"plural": {form: unit(value) for form, value in forms.items()}}}


with open(catalog_path, encoding="utf-8") as file:
    catalog = json.load(file)

missing = []
for key, entry in catalog["strings"].items():
    if entry.get("extractionState") == "stale":
        continue
    localizations = entry.setdefault("localizations", {})
    if key in singular:
        localizations["en"] = plural({"one": singular[key], "other": key})
    translation = russian.get(key)
    if translation is None:
        if key.strip():
            missing.append(key)
    elif isinstance(translation, dict):
        localizations["ru"] = plural(translation)
    else:
        localizations["ru"] = unit(translation)

# Strings the code no longer has.
stale = [key for key, entry in catalog["strings"].items() if entry.get("extractionState") == "stale"]
for key in stale:
    del catalog["strings"][key]

with open(catalog_path, "w", encoding="utf-8") as file:
    json.dump(catalog, file, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    file.write("\n")

unused = sorted(set(russian) - set(catalog["strings"]))
print(f"{len(catalog['strings'])} strings, {len(catalog['strings']) - len(missing)} in Russian, {len(stale)} removed.")
if missing:
    print("Not translated yet:")
    for key in sorted(missing):
        print("  " + key.replace("\n", "\\n"))
if unused:
    print(f"{len(unused)} translations are for strings the code no longer has, for example: {unused[:5]}")
