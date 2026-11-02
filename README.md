# Aktar

<p align="center">
  <img src="docs/logo.png" alt="Aktar logo" width="120">
</p>

<p align="center"><strong>Your files. Your storage. One shortcut away.</strong></p>

A macOS menu bar app for uploading files to your own S3-compatible storage.
Drag a file, paste from the clipboard, or drop it anywhere in the app, and
get a public link back on your clipboard.

## Features

- Lives in the menu bar (`LSUIElement`, no Dock icon)
- Drag & drop, clipboard paste, or file picker to upload; text on the
  clipboard uploads as a file, and a copied link's file is downloaded and
  re-hosted in your bucket
- Capture: one shortcut to select an area or a window with macOS's own
  screenshot tool, uploaded with its link copied
- The link is copied right away, before a large upload finishes; offline,
  uploads wait and go on when you're back, even after a restart
- Upload and paste: one shortcut uploads the clipboard (or a capture) and
  pastes the link where you're typing
- Undo for 10 seconds after an upload: deletes the file and its short link
  and puts back what was on the clipboard
- Bring your own storage: Amazon S3, Cloudflare R2, Backblaze B2,
  DigitalOcean Spaces, MinIO, or any other S3-compatible endpoint
- Multiple destinations, switchable per upload
- Upload history with search, thumbnails, and previews (images, PDFs, text,
  Markdown)
- Copy the link as a plain URL, Markdown, HTML, or a custom template
- Delete the remote file straight from the history view
- Watched Folders: files that land in a folder you pick (your screenshots
  folder, for one) are uploaded on their own, each folder with its own
  destination, path, filters and what happens to the original afterwards
- Expiring uploads: "Delete after" 1, 7, 14, or 30 days, deleted by the
  bucket's own lifecycle rules even when Aktar isn't running
- Browse each bucket folder by folder, including files uploaded elsewhere:
  search the whole bucket, preview, copy links or temporary links, upload into a folder, create
  folders, rename, move, and delete
- [Raycast extension](https://www.raycast.com/merttopuz/aktar): upload,
  search history, and browse buckets from Raycast (opt-in, see Settings >
  Integrations)
- Launch at login

## Install

Download the [latest DMG](https://github.com/getaktar/mac/releases/latest/download/Aktar.dmg),
or install with [Homebrew](https://brew.sh):

```bash
brew install --cask getaktar/tap/aktar
```

Aktar updates itself, so there's no need to run `brew upgrade` for it.

## Privacy & security

Your storage credentials are kept in the macOS Keychain and never leave your
Mac except in direct requests to the S3-compatible endpoint you configure.
Aktar has no backend, no telemetry, and no account system. The only other
request it makes is the update check ([Sparkle](https://sparkle-project.org)),
which downloads `appcast.xml` from this repository's latest GitHub release and
sends no information about you or your Mac; you can turn it off in Settings.
When you upload a link you copied, Aktar downloads that file (no cookies, no
cache) to upload it to your storage.
Capture needs the Screen Recording permission (macOS's screenshot tool runs on
Aktar's behalf), and pasting links for you needs Accessibility (Device Control
and Data Access on macOS 27; Aktar presses ⌘V); both are asked for only when
you use those features. An upload whose
link was copied before it finished is kept in Aktar's container until it's
uploaded, then deleted.
If you turn on Settings > Integrations > Allow local connections (off by
default, and what the Raycast extension uses), Aktar also listens on
`127.0.0.1` for requests carrying a random token that is kept in the Keychain.
It never accepts connections from other machines or from web pages.
Before sending the token, a companion can check that it's really talking to
Aktar: `GET /v1/hello?nonce=<16 to 128 characters of A-Z, a-z, 0-9, - or _>`
needs no token and answers `{"app": "Aktar", "proof": "<hex>"}`, where the
proof is the lowercase hex HMAC-SHA256 of `aktar-hello-v1:<nonce>` keyed with
the token (an invalid or missing nonce gets 400). When an app other
than Finder asks Aktar to upload files (through the Services menu or the
Share menu), Aktar asks you first.
A watched folder's webhooks, if you add any, send each upload's link and
file name to the address you give.
See [SECURITY.md](SECURITY.md) for the disclosure policy.

## Requirements

- macOS 14+
- [Xcode](https://developer.apple.com/xcode/)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Building

The Xcode project is generated from `project.yml` and isn't committed to
the repo, so generate it after cloning:

```bash
brew install xcodegen
xcodegen generate
open Aktar.xcodeproj
```

Select your own Team under Signing & Capabilities, then build and run
(`Cmd+R`).

The unit tests (the Watched Folders engine) run with `Cmd+U`, or:

```bash
xcodebuild test -scheme Aktar CODE_SIGNING_ALLOWED=NO
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md).
Changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)

## Other platforms

Windows, iOS, and Android clients are in progress - see the
[getaktar organization](https://github.com/getaktar) for other repos.
