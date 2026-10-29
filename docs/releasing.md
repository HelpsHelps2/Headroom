# Releasing

Headroom ships as a Developer ID–signed, notarized DMG on GitHub Releases. The App Store sandbox would block the process and Git inspection that keep in-use folders safe.

## One-time setup

1. **Developer ID certificate.** In Xcode, open Settings → Accounts, select your Apple ID and team, choose Manage Certificates, then add a **Developer ID Application** certificate. Only the team's Account Holder can create one. Confirm it is installed:

   ```sh
   security find-identity -v -p codesigning   # expect "Developer ID Application: Your Name (TEAMID)"
   ```

2. **Notarization credentials.** Create an app-specific password at account.apple.com → Sign-In and Security → App-Specific Passwords. Then store it in the keychain under the profile the release script uses. The command prompts for the password, so it never appears in shell history:

   ```sh
   xcrun notarytool store-credentials headroom-notary --apple-id you@example.com --team-id TEAMID
   ```

If you have more than one Developer ID certificate, set `HEADROOM_SIGNING_IDENTITY` to the full name. `HEADROOM_NOTARY_PROFILE` overrides the profile name. `HEADROOM_BUNDLE_ID` overrides the default `io.github.helpshelps2.headroom`; keep it stable once released.

## Each release

1. Set the new version in `VERSION` and add a matching `## x.y.z` section to `CHANGELOG.md`. Commit.
2. Build, sign, notarize, and staple:

   ```sh
   scripts/release.sh            # dist/Headroom-x.y.z-arm64.dmg and .sha256
   ```

   `scripts/release.sh --unsigned` builds the same DMG with an ad-hoc signature, to test packaging without credentials.
3. Tag and publish:

   ```sh
   scripts/publish-release.sh    # tags vX.Y.Z, pushes the tag, creates the GitHub release with the DMG and checksum
   ```

The script refuses to publish a dirty tree, an existing tag, a DMG that is not stapled, or a version without changelog notes.

## Installer window

[dmgbuild](https://github.com/dmgbuild/dmgbuild) lays out the DMG window without scripting Finder, so it works in CI. `release.sh` installs the pinned versions from `scripts/dmg/requirements.txt` into `.build/dmg-venv` on first use. The window background is `scripts/dmg/background.html`, rendered to the committed `background.png` and `background@2x.png` by `scripts/dmg/render-background.sh`. Icon positions in `scripts/dmg/settings.py` must match the ring centers in the HTML.

## Download links

The product website lives in a separate repository. Its download buttons ask the GitHub API for the latest release and link the asset whose name ends in `-arm64.dmg`, so publishing a release updates the site with no other change. Keep that suffix when renaming release assets.

## Later

A Homebrew cask (`brew install --cask headroom`) and Sparkle in-app updates both build on the notarized DMG from this process.
