# Releasing Sheaf

Everything here needs things only you have: an Apple developer account, a Developer ID
certificate, and somewhere to host downloads. The scripts are written, and the parts
that need none of that have been run.

## Once

1. **Developer ID.** In Xcode ▸ Settings ▸ Accounts, add your Apple ID and create a
   "Developer ID Application" certificate. `security find-identity -v -p codesigning`
   lists it; its full name is what `DEVELOPER_ID` below wants.
2. **Notarization credentials.** Make an app-specific password at appleid.apple.com, then:

   ```bash
   xcrun notarytool store-credentials sheaf-notary --apple-id you@example.com --team-id TEAMID
   ```

## Each release

1. Set the version in `project.yml` (`MARKETING_VERSION`, and raise `CURRENT_PROJECT_VERSION`).
2. Check everything:

   ```bash
   make ci && make corpus
   ```

3. Bring the translations up to date. This lists any string that has no Russian yet:

   ```bash
   make strings
   ```

4. Build, sign, notarize and pack:

   ```bash
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID NOTARY_PROFILE=sheaf-notary Scripts/release.sh
   ```

   The result is `build/release/Sheaf-<version>.dmg`, signed, notarized and stapled.
   Without `DEVELOPER_ID` the script makes an image that only runs on this Mac, which is
   how it has been tested so far.
5. Go through `VERIFY.md` on the built app, at least the sections touched since last time.

## Updates (Sparkle)

The app has a "Check for Updates…" command that appears once Sparkle is part of the
project. It is not yet, because adding it downloads Sparkle from GitHub, and that is
yours to approve. To switch it on:

1. In `project.yml`, add under `packages:`

   ```yaml
     Sparkle:
       url: https://github.com/sparkle-project/Sparkle
       from: "2.6.0"
   ```

   and under the Sheaf target's `dependencies:` add `- package: Sparkle`.
2. Make a signing key for updates and note the public key it prints:

   ```bash
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

3. In `Sheaf/Resources/Info.plist` add `SUFeedURL` (where `appcast.xml` will live) and
   `SUPublicEDKey` (the public key).
4. The app is sandboxed, so add Sparkle's XPC services as its documentation describes
   ("Sandboxing" page), and the `com.apple.security.network.client` entitlement.
5. After each release, run Sparkle's `generate_appcast` on the folder holding the disk
   images and upload the images and `appcast.xml`.

`Sheaf/App/Updater.swift` needs no change: it compiles its Sparkle code only when the
package is there.

## The Help Book and translations

- `Scripts/make-help.py` holds every help page and writes `Sheaf/Resources/Sheaf.help`.
- `Scripts/localize.py` (or `make strings`) syncs `Localizable.xcstrings` with the code
  and applies the Russian in `Scripts/translations/`. Help is in English only for now.
