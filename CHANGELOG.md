# Changelog

All notable changes to Aktar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- When another app asks Aktar to upload files through the Services menu
  ("Upload with Aktar") or the Share menu, Aktar now asks first, naming the
  files and the destination they'd go to. Uploads you start from Finder
  aren't asked about
- Connecting Raycast only hands over the local API token when the app that
  opens Raycast links is Raycast itself, signed by Raycast. Otherwise
  nothing is shared and Aktar says why
- Importing a destination from another device now shows where its files and
  links go before anything is saved: the storage and link hosts, the
  short link service, each webhook and script, its "Use for" rules and its
  output template. Webhooks and scripts come in turned off, and "Use for"
  rules and the template are left out, unless you keep them there. When
  updating a destination you already have, its own webhooks, scripts and
  "Use for" rules stay as they were unless you keep the imported ones
- The local API answers `GET /v1/hello` without the token, with a proof
  that only Aktar (which knows the token) can make, so Raycast and the CLI
  can check they're talking to Aktar before sending the token
- The local API refuses request bodies larger than 5 TB or larger than the
  free disk space (keeping 2 GB free), and more than 32 connections at once
- Files handed over by a Shortcuts action can no longer be written outside
  Aktar's temporary folder, whatever their name
- A watched folder's file is only uploaded, moved to Trash or moved to
  "Uploaded" while it's still the same file Aktar checked: a file or link
  swapped in at its path is left alone (and an upload of it is tried again
  later). An "Uploaded" that is a link to another folder is never used
- XSLT stylesheets (.xsl, .xslt), .shtml pages and web archives (.mht,
  .mhtml) are uploaded with "Content-Disposition: attachment" like HTML, so
  opening their link downloads them instead of running them on your
  bucket's domain
- Thumbnails of bucket files are made from a download with a safe file
  name, whatever the file's key

## [0.17.0] - 2026-10-07

### Added

- Clean URLs: `{short}` in a path template becomes a random 7-character
  code (0-9, A-Z, a-z, from the system's secure random generator), for
  links like `files.example.com/A7kdP2x.png`. It never replaces a file:
  on Amazon S3 and Cloudflare R2 the upload is only written if the key is
  new (`If-None-Match: *`, also when completing a multipart upload), on
  other providers the key is checked first; a taken key gets a whole new
  code, and after 5 tries the upload fails with nothing overwritten.
  New destinations use `{year}/{month}/{short}.{ext}`; saved ones keep
  their path. Set Up Cloudflare R2 uses `{short}.{ext}` with a domain of
  your own and the new default with r2.dev (docs/short-links.md)
- A presets menu next to the destination's path: Clean URL (Recommended),
  Short with Date and Original File Name
- A destination whose links use a domain of your own and whose path has
  no `{short}` suggests Clean URLs in its form, with an example on that
  domain; the note can be dismissed for each destination
- Short links with your own shortener: a destination's new Short Links
  section picks Shlink, YOURLS, Kutt, Dub, Short.io or a custom HTTP
  request, with its address, domain and API key (kept in the Keychain),
  a Test button, "Only shorten links longer than" and "Also shorten
  temporary links" (for shorteners that can expire links; the short link
  expires with the temporary link). After an upload the short link is
  what's copied (URL, Markdown, HTML, and `{url}`, `{shortUrl}` and
  `{longUrl}` in a custom template) and what the QR code shows; an
  expiring upload's short link expires with it. If it can't be created
  the original link is copied and a notification offers Retry. http://
  addresses need "Allow insecure HTTP". Hosted shorteners are marked as
  seeing every link and click (docs/short-links.md)
- History shows an upload's short link with its clicks and last click,
  and offers Copy Short Link, Copy Original Link, Create Short Link and
  Delete Short Link; earlier short links are listed with their status
- Deleting a file deletes its short links too; one that can't be deleted
  is marked "may still exist" and you're told. Renaming or moving a file
  in the bucket view points its short link at the new path when the
  shortener can (and keeps the old file if that fails); otherwise it
  warns first. A reused duplicate reuses its short link, and Replace File
  keeps it
- Import ShareX Configuration (.sxcu) in the Short Links section reads a
  ShareX custom URL shortener into a custom HTTP request. It first shows
  where your token will be sent (host, method, endpoint, and which
  headers or parameters carry it); secrets found in the file are moved to
  the Keychain. Configurations that use regular expressions, `{response}`,
  file fields, `{select}`, `{prompt}` or other ShareX syntax are refused
  with the reason, and http:// needs "Allow insecure HTTP"
- Testing a custom HTTP shortener with a delete request deletes the test
  link again, and says whether that worked. A custom delete request can
  use DELETE, GET or POST
- Local API: uploads have `shortUrl` (null without one) and their formats
  use it; `short=1` or `short=0` on an upload overrides the destination
  for that upload; `GET` and `POST /v1/uploads/{id}/short-link` read
  (with clicks) or create an upload's short link; moving an object
  reports `shortLinkStatus`
- Webhooks and scripts after an upload get `upload.shortUrl` (null
  without one), also for watched folders
- Share to Another Device carries the destination's short link settings
  and token

### Fixed

- A Short.io delete that answers 200 with `"success": false` counts as a
  failed cleanup ("may still exist") instead of a deleted link
- Remove from History also removes that upload's short link records from
  Aktar (the short links themselves are left alone)
- Deleting an object through the local API cleans up its uploads' short
  links, like the bucket view does

## [0.16.0] - 2026-10-06

### Added

- Set Up Cloudflare R2: opens Cloudflare's token page with the permissions
  filled in, and with the pasted token creates the bucket (or uses an
  existing one), turns on public links (the r2.dev address or a domain on
  the Cloudflare account), saves the destination with keys made from the
  token, and tests it. The token itself isn't stored. It's the main button
  in Settings > Destinations when there's no destination yet
  (docs/cloudflare-setup.md)

## [0.15.0] - 2026-10-05

### Added

- Nine more languages: Traditional Chinese, Korean, Italian, Dutch, Polish,
  Russian, Ukrainian, Indonesian and Vietnamese

## [0.14.0] - 2026-10-05

### Added

- Use For on each destination: pick file types (Images, Videos, Audio,
  Documents, Archives) and extensions, and files of those types go there
  when an upload doesn't name a destination (the clipboard shortcut, the
  menu bar, Finder, the Share menu, Shortcuts, the local API). An extension
  wins over a type; a tie goes to the default destination. Files of one drop
  that go to different destinations are still copied together, in order.
  The drop area lists where files go
- A keyboard shortcut for each destination that uploads the clipboard
  there, whatever Use For says
- Replace File… in History and the bucket view (and the local API): a new
  file is written at the same key, so its link keeps working. Metadata
  removal and resizing apply, a format conversion doesn't. History keeps
  the entry with a Replaced date, an expiring file starts its days again,
  and the thumbnail is made again
- Replacing Files on each destination: a short cache time (one minute) for
  everything uploaded there, and an optional Cloudflare zone ID and API
  token that clear a replaced file from Cloudflare's cache right away, also
  when a watched folder keeps a link by writing over its upload
- After Upload on each destination: the same webhooks and scripts as a
  watched folder's Automation, run after each upload made by hand and each
  replace, with `"event": "upload.replaced"` for a replace
- Shortcuts actions: Upload File, Upload Clipboard, Replace File and Get
  Recent Uploads, which return links, with destinations and uploads to pick
  from. Uploads without a destination follow Use For
- Local API: `POST /v1/uploads/{id}/replace` and
  `PUT /v1/destinations/{id}/objects?key=`, and an upload without
  `destinationId` follows Use For. Destinations report `useFor`,
  `shortCache`, `hasCloudflarePurge` and their hook count
- Share to Another Device carries Use For, the short cache setting, the
  Cloudflare zone and token, and the hooks

## [0.13.0] - 2026-10-05

### Added

- Thumbnails for videos, PDFs, RAW photos, Office and iWork documents, fonts
  and more, made with Quick Look the way Finder makes them, in History, the
  menu bar and the bucket view. Files already in a bucket get one when
  they're shown (up to 25 MB), and a file's details show its thumbnail when
  there's no other preview
- A Thumbnails setting for each destination: Off (nothing is made or
  downloaded), On This Mac (the default) or In the Bucket, which also saves
  them to a folder of your choice in the bucket so your other devices can
  show them. A thumbnail in the bucket is deleted, renamed, moved and expires
  together with its file, and its folder is hidden in the bucket view.
  Leaving that mode asks whether to delete the thumbnails already there.
  Shared with Share to Another Device
- Videos and audio files play right in a file's details in History and the
  bucket view, streamed from the bucket (private buckets too) without
  downloading them first. Nothing loads until you click Play
- Local API: `GET /v1/uploads/{id}/thumbnail` and
  `GET /v1/destinations/{id}/thumbnail?key=` return a file's thumbnail as
  a PNG (`px` sets its size, `generate=0` only returns one that's at hand),
  for the Raycast extension's icons and previews
- Settings > General shows how much space thumbnails take on this Mac, with
  Clear to remove them all (they're made again when shown)

### Fixed

- A screenshot pasted from the clipboard gets a thumbnail in History again

### Changed

- Thumbnails are kept next to the history instead of in Caches, so macOS or
  a cleaner app emptying caches no longer leaves rows with only an icon
- Thumbnails are sharper (512 pixels instead of 320) yet take about a tenth
  of the space, as WebP instead of PNG

## [0.12.1] - 2026-10-04

### Fixed

- "Reuse links for duplicate files" no longer hands out a link that now
  serves a different file. With a path like `{filename}.{ext}`, a file
  uploaded under a name another file has since taken is uploaded again,
  and so is one whose file in the bucket changed size or was written
  after it was uploaded
- A file uploaded while the Library showed History (or was closed) now
  shows up when you go back to the bucket. Before, the bucket kept showing
  the listing from before the upload until you clicked Refresh
- Changing a destination's settings while its bucket was open in the
  Library no longer leaves the bucket looking empty, and an error from
  listing it again is shown instead of an empty list
- A large upload that's picked up where it stopped no longer keeps its old
  name in the bucket after you rename the file or change the destination's
  path. It starts over under the new name, and the unfinished upload is
  removed from the bucket
- An aktar://watch/pause link or local API call with a huge number of
  minutes no longer crashes Aktar. Pauses are capped at one year, and a
  link with minutes that aren't a positive whole number is ignored
- A destination whose Public Base URL isn't a valid web address no longer
  crashes Aktar. Settings now says what's wrong and won't save it, a
  transfer link carrying one is turned away, and uploads to a destination
  saved with one stop with a clear error
- A path without {uuid}, {random}, {md5} or {sha256} (such as a watched
  folder's default) no longer replaces a file that already has that name
  in the bucket: the new one is numbered ("name 2.png"). A watched folder
  set to replace its upload when a file changes still replaces it, so the
  link stays
- Deleting an older history entry whose name was uploaded again later no
  longer deletes the newer file. Only the history entry goes, and the
  confirmation says so
- Expiring uploads are only deleted by Aktar while the bucket really has
  the auto-delete rules. The rules are read on each check; if they're
  gone, auto-delete is turned off for that destination and nothing is
  deleted
- Images copied from the clipboard and items shared from the Share menu
  get their own temporary folders, so two copied within the same second
  no longer overwrite each other. Clipboard images are deleted once the
  upload is done or cancelled, and Aktar's temporary folders are emptied
  at launch
- Copying a web link no longer makes "Upload from Clipboard" try to upload
  the link as a file. An image copied along with it is uploaded instead
- Text, code, Markdown and PDF previews skip files over 25 MB instead of
  downloading them whole, and nothing they download is cached on disk

### Security

- Images over 100 megapixels are no longer converted, compressed, resized,
  previewed or given a thumbnail, so a small file claiming huge dimensions
  can't use up all memory. They go up as they are, still without the
  metadata the destination removes; if that can't be done without
  decoding the image, the upload stops with an error instead
- HTML, SVG, XML and JavaScript files are uploaded with
  "Content-Disposition: attachment", so opening their link downloads them
  instead of running them on your bucket's domain. An SVG in an <img> tag
  still shows
- "Remove location" and "Remove all" now also cover WebP, AVIF and GIF
  images, a PNG's text chunks (under "Remove all"), and .mov, .mp4 and
  .m4v videos, which are copied without re-encoding and without their
  location (or all metadata). This also applies inside folder ZIPs. A file
  that can't be cleaned isn't uploaded
- aktar://upload-clipboard and aktar://watch/pause links now ask before
  uploading the clipboard or pausing watched folders, since any web page
  can open them
- Transfer links expire an hour after they're made. Copy Transfer Link and
  the local API token are marked as concealed for clipboard managers, and
  closing the transfer window clears the copied link from the clipboard
- Watched folder webhooks must use https:// (plain http:// only for this
  Mac or the local network) and don't follow redirects to another host
- HTML and Markdown output escape the file name, so a crafted name can't
  add markup to what you paste
- Names typed in the bucket browser (new folders, rename or move), and
  folder names, prefixes and move targets sent to the local API, can't
  contain "." or ".." segments, empty folder names, control characters or
  a leading "/" (a lone "/" still means the bucket's top level). {filename}
  in a path drops slashes and control characters
- Every storage request that doesn't carry file data (listing, deleting,
  copying, lifecycle rules, starting and finishing large uploads) now
  gives up after 60 seconds instead of possibly waiting forever

## [0.12.0] - 2026-10-03

### Added

- Share to Another Device (a destination's menu in Settings >
  Destinations): shows the destination, keys included, as a QR code for
  Aktar on another device, with a transfer code to type there. The keys
  are encrypted with that code, which is never in the QR code or the
  link, so Copy Transfer Link can be sent on its own. The window closes
  itself after 10 minutes, and every opening makes a new code
- Import from Another Device (Settings > Destinations and the Welcome
  window): scan the QR code with the Mac's camera or paste the link and
  type the transfer code, which formats itself as XXXX-XXXX-XXXX. The
  destination is saved right away, then Test Connection runs by itself
  and its result is shown, with Edit to change anything. A destination
  that's already here can be updated or added as a copy. aktar://import
  links open it with the link filled in

## [0.11.1] - 2026-10-03

### Fixed

- Deleting the files of a large batch that was waiting for "Upload" or
  "Skip" in a watched folder now withdraws the question. Before, the
  question stayed until Aktar restarted, and the folder held every new
  file back behind it instead of uploading it. "Upload" and "Skip" also
  leave out files that were deleted in the meantime

## [0.11.0] - 2026-10-02

### Added

- Watched Folders (Settings > Watched Folders): files that land in a
  folder you pick are uploaded on their own, once they're completely
  written. Each folder has its own destination, path, link and "Delete
  after", which files count (all, images, videos, screenshots only, or
  your own patterns, with sizes and subfolders), what happens when a file
  changes (ignore it, upload it again, or replace the upload so the link
  stays), and what happens to the original afterwards (keep it, move it
  to the Trash or an "Uploaded" subfolder, or tag it "Aktar" in Finder).
  Partial downloads, temporary and hidden files are never uploaded, a
  renamed file isn't uploaded twice, and files that arrived while Aktar
  wasn't running are picked up when it starts
- When a file is deleted from a watched folder, its upload can be
  deleted from the bucket too (off by default, for folders that keep
  their files). It waits a few seconds in case the file comes back and
  never deletes an upload something else still uses. "Ask before
  deleting" (on by default) asks first every time, in the menu bar and in
  a notification whose Delete from Bucket and Keep Uploaded Files buttons
  work without opening Aktar; with it off, Aktar still asks when many
  files disappear at once
- Upload Screenshots Automatically: watches the folder macOS saves
  screenshots to and copies each screenshot's link as soon as it's up
- More than 50 new files at once wait for Upload or Skip, in the menu bar
  and in Settings, so a folder dropped in by mistake isn't shared
- Pause watching for an hour, until tomorrow or until you resume it, from
  the menu bar or Settings, and on battery power or Low Data Mode and
  metered networks if you like. Files that arrive meanwhile wait in their
  folder
- Automation for each watched folder: call a webhook or run a script from
  Aktar's scripts folder after every upload, with the link, the key and
  the file
- "Watch Folder with Aktar" in Finder's right-click menu for folders
- {folder} and {subpath} in Object Path: the watched folder's name and the
  subfolders a file is in
- Uploads from watched folders say where they came from in the menu bar
  and the Library, which can show only those
- The local API can list, pause and resume watched folders
  (/v1/watched-folders), and aktar://watch, aktar://watch/pause and
  aktar://watch/resume do the same from a link

### Fixed

- "Show notification after upload" in Settings > General is respected

## [0.10.0] - 2026-10-01

### Added

- Show QR Code for an upload, in the Library (right-click, the detail
  view's link and its menu) and in the menu bar's recent uploads. It shows
  the link copying would give (a fresh temporary link when the
  destination uses them), crisp at any size, with Copy Image and Save
  Image. Copy Temporary Link can show one as a QR code too
- Reuse links for duplicate files (Settings > General, on by default): a
  file that's already in the same destination, expiring the same way, is
  not uploaded again; its existing link is copied instead. Uploads to an
  exact place (the bucket browser, the local API's prefix=), folders and
  ZIPs are always uploaded. The local API's upload reply says whether the
  link was reused
- {md5} and {sha256} in a destination's Object Path, the hash of the
  uploaded file's contents
- Rename before upload: hold Option while dropping, pasting or choosing
  files in the menu bar to name each one first, or give "Rename and
  upload clipboard" its own shortcut in Settings > General. The name
  replaces {filename} and is what history shows
- Image Processing in each destination: convert photos to WebP or AVIF,
  recompress them (Light, Medium or Strong) and shrink them to a longest
  side of 3840 to 1024 px. Orientation is applied, the color profile is
  kept and Image metadata still decides what else stays. Applies to
  JPEG, PNG, HEIC, WebP, TIFF and BMP; GIFs, SVGs and files inside ZIPs
  are left alone. Off by default

### Changed

- Big files go up as multipart uploads, up to four parts at a time, so
  there's no 5 GB limit anymore and files are never read into memory
  whole. Every upload shows real progress, and a dropped connection or a
  busy provider is retried on its own
- A failed big upload continues where it stopped on Retry, and uploading
  the same file again (even after quitting Aktar) resumes it, saying
  "Resuming upload". Unfinished uploads older than 7 days are cleaned up
- Uploads in progress can be cancelled from the menu bar and the Library,
  which also frees what was already sent to the bucket

## [0.9.1] - 2026-09-30

### Added

- 5 minute and 15 minute temporary links, in the menu bar's Link choice,
  a destination's Upload Defaults and Copy Temporary Link. For credentials
  and other confidential files, the link stops working minutes after it's
  sent, and Delete Remote File removes the file once it has arrived

## [0.9.0] - 2026-09-30

### Added

- Folder uploads: drop a folder on the menu bar, send it from Finder's
  Services or Share menu, or copy it and use the shortcut. A new Folders
  choice in each destination's Upload Defaults uploads it as one ZIP (the
  default, one link to share) or file by file with its subfolders, under a
  new folder in the bucket, copying all the links at once when it's done.
  Hidden files such as .env, .git and .DS_Store are left out either way,
  and photos lose their metadata as Image metadata says, inside a ZIP too
- Dropping a folder into the bucket browser uploads it with its structure
  into the current folder

## [0.8.0] - 2026-09-30

### Added

- Image metadata in each destination's Upload Defaults: photos lose their
  GPS location before they're uploaded (the default), lose all metadata
  (camera, lens, date, location), or are uploaded as they are. Orientation
  and color profile are kept, the image isn't recompressed where the
  format allows it, and files without anything to remove are uploaded
  untouched. If the metadata can't be removed, the upload stops instead of
  sharing the location. Covers JPEG, HEIC, PNG and TIFF, from every way of
  uploading, including the Finder service, the Share menu and the local API

### Fixed

- Editing a destination could open an empty form, as if adding a new one.
  The form now always opens with the destination you clicked, and the key
  fields say "Unchanged" when the saved keys are kept

## [0.7.0] - 2026-09-30

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
