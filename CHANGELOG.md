# Changelog

All notable changes to Aktar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
