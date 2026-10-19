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

## Private Cloud Compute

Settings ▸ Intelligence offers Private Cloud Compute for summaries and answers only in a
copy of Sheaf that holds the entitlement `com.apple.developer.private-cloud-compute`.
Apple manages it: without it macOS refuses the request ("Operation not permitted"), and a
build signed with a development certificate is stopped by the framework with "Missing
entitlement". Sheaf checks for it and sends nothing without it.

1. Sign in to the developer account and ask for it at
   <https://developer.apple.com/contact/request/private-cloud-compute/>. Apple lists
   eligibility requirements there.
2. Once granted, turn the capability on for the App ID `com.valeryburtsev.Sheaf`, and make
   provisioning profiles that carry it: a development one, and a Developer ID one for
   releases. A managed entitlement only counts when a profile in the app vouches for it.
3. Add `<key>com.apple.developer.private-cloud-compute</key><true/>` to
   `Sheaf/Resources/Sheaf.entitlements`, and set `DEVELOPMENT_TEAM`, the signing identity
   and the profile in `project.yml`. With "Sign to Run Locally" the key must stay out:
   an ad hoc signed app that claims a managed entitlement does not launch.
4. The choice then shows by itself in Settings (a new Intelligence pane) and at the
   bottom of the Summary panel; both are hidden without the entitlement. Put a section
   about it back into the help page (`Scripts/make-help.py`, "intelligence"), and say in
   the "Summarize PDF" action's description that it follows the setting.
5. Then try it: `-SnapshotAssistant cloud,summary` should print `by cloud`. Nothing past
   this point has run against the real service, so expect to adjust the size of the parts
   (`Reader.inputTokens`) and the prompts.

## Mac App Store

Not set up yet (2026-10-14). Decided so far:

- The privacy manifest is `Sheaf/Resources/PrivacyInfo.xcprivacy`: no tracking, no data
  collected, and reasons for UserDefaults, system uptime and file creation dates. Check it
  whenever code starts using another API from Apple's "required reason" list.
- Reply to Sender keeps its Mail permission (`com.apple.security.temporary-exception.apple-events`)
  in the first submission, explained in the review notes: the person chooses Reply, Sheaf
  reads only the message the PDF came from, to quote it in a draft, and sends nothing.
  Only if App Review rejects it does the App Store build fall back to New Mail Message.
- Sparkle stays out of the App Store build.
- Still to do: team and Apple Distribution signing, a Mac App Store provisioning profile,
  an archive exported for App Store Connect, the App Store Connect record, a public
  privacy policy URL, support URL, screenshots, age rating, and the export compliance answer.

## The Help Book and translations

- `Scripts/make-help.py` holds every help page and writes `Sheaf/Resources/Sheaf.help`.
- `Scripts/localize.py` (or `make strings`) syncs `Localizable.xcstrings` with the code
  and applies the Russian in `Scripts/translations/`. Help is in English only for now.
