# Sheaf

A native macOS PDF editor. The roadmap and architecture are in [PLAN.md](PLAN.md).

## Layout

- `Sheaf/` is the app: SwiftUI with AppKit where needed.
- `Packages/SheafKit/` is the in-house PDF engine, with its tests and fixture PDFs.
- `project.yml` defines the Xcode project. `Sheaf.xcodeproj` is generated and not committed.

## Building

Requires macOS 26 or later, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
make project   # generate Sheaf.xcodeproj
make run       # build and launch
make test      # engine tests
make corpus    # engine against every PDF that ships with macOS and Xcode
make strings   # sync the string catalog and apply the Russian translation
make help-book # rewrite the Help Book from Scripts/make-help.py
make release   # a disk image; see RELEASING.md for signing and notarizing
```

[VERIFY.md](VERIFY.md) lists what has to be tried by hand, since the automated checks
cannot click, drag or use a scanner.

`Scripts/snapshot.sh <dir> [files]` launches the debug build and saves a PNG of each
window, which is how UI changes are checked from the command line.
