# Changelog

All notable changes to Aktar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- "Upload with Aktar" in Finder: right-click files and choose it under
  Services to upload them to the selected destination, with its copy
  format, Link and Delete after. Folders are skipped
- The same service can get a keyboard shortcut in System Settings >
  Keyboard > Keyboard Shortcuts > Services, which then uploads whatever is
  selected in Finder
- Aktar in the Share menu of Finder, Photos, Safari and other apps. macOS
  keeps new Share menu extensions off until you turn them on

## [0.6.0] - 2026-09-30

### Added

- A "Link" choice next to "Delete after" in the menu bar and in each
  destination's Upload Defaults: copy the public URL, or a temporary link
  valid for 1 hour, 24 hours or 7 days. Temporary links work for private
  buckets, so a profile like "Temporary: 24 hours, delete after 1 day" or
  "Private team bucket: 7 days" needs no trip to the provider's dashboard
- Copy Temporary Link for uploads in the menu bar's recent list and in the
  Library, to share a file again with a fresh link

## [0.5.3] - 2026-09-30

### Added

- Upload profiles: each destination keeps its own "Copy as" (URL, Markdown,
  HTML or custom) and "Delete after", set in the destination's Upload
  Defaults. Pick "Builds", "Logs" or "Screenshots" in the menu bar and
  uploads go to that bucket and path with its settings
- Duplicate in a destination's menu in Settings, to start another profile
  on the same bucket with the same keys

### Changed

- The menu bar's "Delete after" choice is saved for the selected
  destination instead of for all of them

### Fixed

- The Settings > Output choice is kept between launches

## [0.5.2] - 2026-09-30

### Changed

- Test Connection shows each step on its own line: whether the upload
  worked and whether the test file's public link opens, with the HTTP status
  when it doesn't (for example 403)
- When the public link fails, the result says what to do: allow public
  reads on the bucket (on R2, turn on the r2.dev URL or connect a custom
  domain), check the Public Base URL, or keep the bucket private and share
  with Copy Temporary Link in the Library

### Fixed

- A bucket that accepts uploads but doesn't serve them no longer gets a test
  result that starts with "Connection successful"
- The public link check retries with GET when a server doesn't answer HEAD

## [0.5.1] - 2026-09-30

### Fixed

- The hourly expiry cleanup only deletes a file itself while the bucket has
  Aktar's rules, the file is still there and it wasn't uploaded again since;
  otherwise it just clears the history entry. Removing the rules keeps
  already uploaded files for good, in history too
- Aktar no longer rewrites a bucket's lifecycle rules when it can't fully
  read the existing ones, so the bucket's other rules can't be lost, and it
  reads the rules back after setting them up
- Files moved or uploaded into a `tmp/{N}d/` folder only count as expiring
  while the bucket has Aktar's rules
- A rules check in the destination form no longer carries over to another
  bucket, endpoint or region entered after it
- Setting up the rules asks first when `tmp/{N}d/` folders already hold
  files, since the bucket would start deleting those too
- The manual setup help names the rule IDs Aktar recognizes

## [0.5.0] - 2026-09-30

### Added

- Expiring uploads: a "Delete after" choice (1, 7, 14 or 30 days) next to the
  destination picker in the menu bar. Expiring files go under `tmp/{N}d/` and
  the bucket deletes them itself through lifecycle rules, so they're removed
  on schedule even when Aktar isn't running. The choice becomes available
  once the destination's bucket has Aktar's rules, which Aktar sets up from
  the same menu or the destination's settings (keeping the bucket's other
  rules). If the key can't manage lifecycle rules, Aktar says which rules to
  add in the provider's dashboard
- Auto-delete can be turned off per destination, keeping or removing the
  bucket's rules
- History, the Library and upload notifications show when an expiring file
  will be deleted
- The local API takes `expires=` (days) on uploads and returns `expiresAt`

## [0.4.1] - 2026-09-28

### Changed

- What's New in Settings > About opens the release notes on getaktar.com in
  the app's language, and the update window links to them too

### Fixed

- "Set as Default" in Settings > Destinations now shows the new default right
  away. The default did change, but Settings kept showing the old one; saved
  settings with this mismatch are corrected on launch

## [0.4.0] - 2026-09-28

### Added

- Bucket browser in the Library window: browse each destination's bucket
  folder by folder (including files not uploaded with Aktar), search the whole
  bucket, preview files, copy links or temporary links that also work for private buckets, upload
  into a folder, create folders, rename or move files, and delete them
- Raycast integration: an opt-in local API (Settings > Integrations, off by
  default, 127.0.0.1 only, token-protected) that the Aktar Raycast extension
  uses to upload files and the clipboard, search history, and browse buckets.
  Pair it from Raycast with "Connect to Aktar", which Aktar asks you to approve
- `aktar://` links: `aktar://upload-clipboard` (only while Aktar is already
  running, so opening a link can't upload the clipboard by launching it),
  `aktar://library`, and `aktar://settings`

### Fixed

- Retrying a failed upload, or uploads queued for different destinations at
  the same time, now go to the destination they were started for instead of
  the current default
- A new upload's row in the Library no longer shows up clipped to half its
  height
- Thumbnails keep the image's aspect ratio (and orientation) instead of being
  squashed into a square, and are sharper on Retina displays

## [0.3.0] - 2026-09-27

### Added

- Localization in Turkish, German, French, Spanish, Brazilian Portuguese,
  Japanese, and Simplified Chinese, matching the languages of getaktar.com.
  The app follows the macOS system language by default; pick a different one
  in Settings > General > Language
- About tab in Settings with version info and links to the website, source
  code, changelog, issue tracker, and developer; the About Aktar panel now
  shows the same links
- Automatic updates via Sparkle: Aktar checks GitHub for new versions and can
  download and install them for you (Settings > General > Updates). This is
  the first version with an updater, so it has to be installed manually once

### Fixed

- App icon now follows the macOS icon shape instead of appearing as a black
  square inside a grey plate

## [0.2.0] - 2026-09-27

### Added

- User-customizable global keyboard shortcut (default ⌃⇧⌘U) to paste & upload
  the clipboard from anywhere, without opening the menu bar panel

## [0.1.0] - 2026-09-26

### Added

- Menu bar upload: drag & drop, clipboard paste, or file picker
- Bring-your-own S3-compatible storage (Amazon S3, Cloudflare R2, Backblaze B2,
  DigitalOcean Spaces, MinIO, or any other S3-compatible endpoint)
- Multiple destinations, switchable per upload
- Upload history with search, thumbnails, and previews (images, PDFs, text,
  Markdown)
- Copy link as URL, Markdown, HTML, or a custom template
- Delete remote files from the history view
- Launch at login
