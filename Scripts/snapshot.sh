#!/bin/sh
# Launches the debug build, optionally opening files, and saves a PNG of each window.
# Works without screen-recording permission: the app captures its own windows.
# Usage: Scripts/snapshot.sh <output-dir> [file ...]   (run `make build` first)
# Extra flags go in SNAPSHOT_ARGS, for example
#   SNAPSHOT_ARGS="-SnapshotNewDocument YES -SnapshotClearsRecents YES"
# See Sheaf/App/DebugSnapshot.swift for the full list.
set -eu
out="$1"; shift
mkdir -p "$out"
app="$(pwd)/build/Build/Products/Debug/Sheaf.app"
rm -f "$out"/*.png "$out/snapshot.log"
# The app saves edits in place when it quits, so it only ever gets copies of the files
# given, never the files themselves.
rm -rf "$out/input"
if [ "$#" -gt 0 ]; then
    mkdir -p "$out/input"
    for file in "$@"; do
        cp "$file" "$out/input/"
        set -- "$@" "$out/input/$(basename "$file")"
        shift
    done
fi
# Through Launch Services, so the sandbox is granted access to the files.
open -n -W --stdout "$out/snapshot.log" -a "$app" "$@" \
    --args -SnapshotWindows ${SNAPSHOT_DELAY:-3} -SnapshotQuits YES -ApplePersistenceIgnoreState YES ${SNAPSHOT_ARGS:-}
python3 - "$out" <<'PY'
import base64, re, sys
out = sys.argv[1]
count = 0
for line in open(f"{out}/snapshot.log", errors="ignore"):
    if not line.startswith("SNAPSHOT "):
        continue
    title, data = line[len("SNAPSHOT "):].rstrip("\n").split("\t", 1)
    name = re.sub(r"[^A-Za-z0-9]+", "-", title).strip("-") or "untitled"
    count += 1
    path = f"{out}/{count}-{name}.png"
    open(path, "wb").write(base64.b64decode(data))
    print(path)
if not count:
    print("no windows captured", file=sys.stderr)
PY
