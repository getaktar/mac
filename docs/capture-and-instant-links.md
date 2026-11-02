# Capture, instant links, upload and paste, undo, clipboard text and links

The main flow, from file to link, in five parts. Shared by the Mac, Windows,
iOS and Android apps; the Mac app implements all of it first, as the
reference, and Windows and mobile follow. Platform notes say what each part
means elsewhere.

| Part | Mac | Windows | iOS | Android |
|---|---|---|---|---|
| 1. Capture | yes | yes | n/a | n/a |
| 2. Instant link and offline queue | yes | yes | yes | yes |
| 3. Upload and paste | yes | yes | n/a | n/a |
| 4. Undo | yes | yes | yes | yes |
| 5. Clipboard text and links | yes | yes | yes | yes |

## 1. Capture (desktop)

One shortcut: pick an area or a window, and the screenshot goes up like a
pasted image, its link copied.

- Entry points: the "Capture and upload" shortcut, "Capture, upload and paste
  the link" (part 3), and a Capture button in the panel next to Paste and
  Browse. The shortcuts are unset by default.
- The upload has no destination of its own: "Use for" routes it as an image
  (destination-automation.md), and the destination's image processing,
  metadata removal and path template apply as for any image.
- File name: `Screenshot 2026-11-02 at 14.03.12.png` (English, like every
  file name Aktar makes), PNG. It's a temporary file, deleted after the upload.
- Cancelling (Esc) uploads nothing and says nothing.
- No editor, annotations or screen recording: capture tools do those better
  (roadmap, "Bilinçli olarak yapılmayacaklar").

Mac: the system's own tool, `/usr/sbin/screencapture -i <file>` (Space switches
between an area and a window, Esc cancels). It checks Screen Recording for the
app that runs it, so Aktar asks for it: without it
(`CGPreflightScreenCaptureAccess`), Aktar explains, and its button calls
`CGRequestScreenCaptureAccess` (which lists Aktar, and may show macOS's own
request) and opens System Settings > Privacy & Security > Screen & System
Audio Recording. Aktar always explains first because macOS doesn't always show
its request (never again after a denial, for one), and the shortcut would
then seem to do nothing. The tool runs inside Aktar's App Sandbox, which
allows it without any extra entitlement: the system's sandbox profile
(`/System/Library/Sandbox/Profiles/application.sb`) lets apps run `/usr/sbin`
tools and lets `/usr/sbin/screencapture` register its
`com.apple.screencapture.interactive` service. If the tool can't start, Aktar
shows what it printed.

Windows: Windows' own snipping bar (the Snipping Tool's overlay), which picks
an area, a window, a free shape or the whole screen and puts the snip on the
clipboard. Snipping Tool's `ms-screenclip://capture` protocol only answers
packaged apps (its response needs the caller's package identity and a
`SharedStorageAccessManager` token), and the old `ms-screenclip:` launch was
retired in May 2025, so Aktar presses Windows+Shift+S (`SendInput`, once the
shortcut's own keys are up) and watches the clipboard sequence number: the
first image put on the clipboard is the snip, as a PNG named the same way
(local time). The wait ends after 60 seconds, or 3 seconds after the
foreground is back on the window that had it before (the bar was closed
without a snip). The clipboard as it was before the capture is what Undo puts
back, never the snip. The entry points are the shortcuts, Capture in the panel
and Capture and Upload in the tray menu. No permission is needed.

## 2. Instant link and the offline queue

The object key is known before the bytes are sent (a `{short}` key is made on
the device), so the link can be copied right away: even a 2 GB video doesn't
keep anyone waiting, and an upload made offline already has its link.

### When

Setting "Copy the link right away" (General > Uploads), on by default. It
applies to an upload the user started of one file (or one folder as a ZIP) to
a key Aktar makes. Not to: a watched folder's files, the files of a folder
uploaded with its structure or of a drop to several destinations (their links
are copied together at the end, as before), a replace (its link doesn't
change), an exact key (bucket view, local API `prefix=`), or an upload someone
waits for (local API, CLI, Shortcuts, Raycast), which returns the link when
it's done, as before.

### Order

1. A copied link is downloaded (part 5).
2. Folder to ZIP, image processing, metadata removal, hashes: all on the
   device, as before. Their result decides the extension and `{md5}`/`{sha256}`.
3. The key, from the path template.
4. Duplicate check: the same bytes already uploaded give the earlier link,
   and nothing is copied early.
5. A path without a unique part (`{short}`, `{uuid}`, `{random}`, `{md5}`,
   `{sha256}`) asks the bucket for a free name first, so its link only comes
   once that can be asked (online). Windows and mobile never did this (such a
   path overwrites what's there), so their link is copied right away there
   too.
6. A multipart upload to resume: its key wins.
7. **The link is copied**: a temporary link is signed on the device, the short
   link is made (part of the link: a short link that can't be made means the
   long link is copied and the failure is told when the upload finishes, where
   Retry has an upload to work on), "Copy as" formats it, it's copied, and
   pasted when asked to (part 3). The panel closes as after an upload.
8. The bytes are sent, then the history entry, thumbnail and hooks follow as
   before. "Uploaded" says it's done.

From step 7 on, the key is pinned: every retry and a restart send the file to
exactly that key, never a new one.

### A key that turns out to be taken

A `{short}` key is written with `If-None-Match: *` on S3 and R2 (and asked
about first elsewhere), so a clash shows up when the write is refused. Before
taking a new key:

- An object at the key as big as this file and written since the first try
  (two minutes of slack) is this upload's own, from a try whose answer was
  lost: the upload counts as done.
- Otherwise the key gets a new code (`ShortKeys`), the short link made for the
  old one is deleted, the new link is copied where the clipboard still holds
  the old one, and a notification says the link changed. (62^7 codes: this is
  for correctness, not something anyone should see.)

### Notifications

- An upload done within 2 s of its link being copied gets only "Uploaded".
- A longer one gets "Link copied / Still uploading. The link works once the
  upload is done." after 2 s, replaced by "Uploaded" when it's done (same
  notification identifier).
- Both have Undo (part 4).

### Offline queue

- A failure for want of a connection (a transient network error, or any
  failure while the system says it's offline) doesn't fail the upload: it
  waits, shown as "Waiting for a connection" with Retry and Cancel, with one
  notification ("The link is copied. The file uploads when you're back online,
  and the link works from then on." or, without an early link, "The file
  uploads when you're back online.").
- It's tried again as soon as the network comes back, and while the network
  looks up after 15, 30, 60, 120 and then every 300 seconds. A multipart
  upload continues from its parts.
- Windows counts as offline only with no connection at all
  (`NetworkInformation.GetInternetConnectionProfile`, level None): offices
  often block the check that confirms internet access while the internet
  works, and a failure for want of a connection waits anyway.
  `NetworkStatusChanged` says when it's back.
- Mobile: `expo-network` says when the network is back, and waiting uploads
  are also tried when the app comes back to the front. A request the system
  refuses on principle (Android's cleartext policy, iOS App Transport
  Security) fails rather than waits.
- This applies to every upload the user started, early link or not. A watched
  folder's files keep their own retries; an upload someone waits for fails as
  before.
- A copied link (part 5) whose download fails for want of a connection, or with
  5xx, 408 or 429, waits the same way.

### Outbox (surviving a quit or restart)

An upload whose link was copied is kept until its bytes are there, so the link
handed out still starts working after Aktar quits, crashes or the computer
restarts.

- Mac: `Application Support/Aktar/Outbox/<job id>/entry.json` and
  `file/<name>`, a copy of the file the upload started from (a clone on the
  same disk, so instant whatever the size; a file on another disk only up to
  512 MB, a bigger one isn't kept and its upload only goes on while Aktar
  runs). Removed when the upload is done, cancelled or undone.
- `entry.json`: `id`, `destinationID`, `originalFilename`, `storedName`,
  `expiryDays`, `shortLinkOverride`, `earlyLink` (`objectKey`, `link`,
  `temporaryExpiresAt`, `shortLink` with `shortUrl`, `providerId`, `provider`,
  `providerName`, `domain`, `targetUrl`, `expiresAt`, `shortLinkError`,
  `copiedText`), `firstAttemptAt`, `failure`. Dates ISO 8601.
- At launch each entry becomes an upload again, to its pinned key. One whose
  destination was removed is dropped (nowhere to send it); one that had
  failed for good waits for Retry or Cancel. Entries older than 7 days are
  dropped with their copy, like unfinished multipart uploads.
- Windows: the same in `%LOCALAPPDATA%\com.getaktar.windows\outbox\` (Local,
  never Roaming AppData: the copies can be big). NTFS has no clone, so a file
  up to 512 MB (and a folder for a ZIP upload, up to 512 MB in all) is copied;
  a bigger file is kept as a hard link on the same disk (instant; apps that
  save by writing a new file and renaming it leave its bytes alone), and one
  that can't be linked (another disk, FAT) isn't kept.
- Mobile: the same in `Documents/Aktar/Outbox/<job id>/`. iOS keeps a copy of
  any size; Android, which has no clones, keeps files up to 512 MB (a bigger
  one only goes on while the app runs). The upload goes on the next time the
  app opens.

## 3. Upload and paste (desktop)

One shortcut uploads and pastes the link where the user is typing: GitHub,
Slack, Linear, a terminal.

- Shortcuts: "Upload clipboard and paste the link" and "Capture, upload and
  paste the link". Unset by default.
- Target: the app in front when the shortcut is pressed (never Aktar itself).
  The link is pasted when it's copied (with an instant link, right away), only
  if that app is still in front and within 30 seconds (for a capture, 30
  seconds from the end of the capture). Otherwise it just stays copied.
- The link stays on the clipboard afterwards, so it can be pasted again.
- Mac: waits until ⌘, ⌥, ⌃ and ⇧ are let go (at most 1.5 s, so the app doesn't
  see ⌃⇧⌘V), then posts ⌘V with `CGEvent` (`flags = .maskCommand`,
  `cgSessionEventTap`). The key is the one that types "v" with ⌘ held in the
  keyboard layout used for shortcuts (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`
  + `UCKeyTranslate`), so it's right on Dvorak, Turkish F and "⌘ QWERTY"
  layouts; `kVK_ANSI_V` if the layout can't be read. Needs Accessibility
  (`CGPreflightPostEventAccess`; without it Aktar explains, and its button
  calls `CGRequestPostEventAccess` and opens System Settings at
  `Privacy_Accessibility`, as for Screen Recording). macOS 27 renamed that list in Privacy & Security
  to "Device Control and Data Access" (same page, same link), so Aktar names
  it by the running version. Without it the upload still happens and the
  link is copied.
- Windows: waits until Shift, Ctrl, Alt and the Windows keys are let go (at
  most 1.5 s), then presses Ctrl+V with `SendInput`, with the key that types
  "v" in the foreground window's layout (`VkKeyScanEx`; Windows layouts give
  letter keys the letter's key code, so it's V on Dvorak, AZERTY and Turkish
  F alike). The target is `GetForegroundWindow` when the shortcut is pressed
  (never one of Aktar's windows), checked again before pasting. A shortcut
  with Alt or the Windows key first taps an unassigned key (0xE8), so letting
  go of Alt doesn't open the app's menu bar (or Start). No permission is
  needed; a window running as administrator doesn't take the keys.

## 4. Undo

For uploading the wrong file, or a screenshot with a password in it.

- What it does:
  - Files still uploading (or waiting) stop; a multipart upload is aborted.
  - Files already up are deleted from the bucket like Delete: the object, its
    bucket thumbnail, its short links (at the provider) and its history entry.
  - A short link made for an early link is deleted at the provider.
  - A link reused from an earlier upload (same file) only leaves the
    clipboard; that file stays, it was uploaded before.
  - The clipboard gets back what was on it before the upload first copied a
    link, but only if nothing was copied since (the change count and the text
    are both checked). A clipboard that couldn't be kept is emptied instead:
    over 64 MB, or marked by a password manager
    (`org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`,
    `com.agilebits.onepassword`), which is never kept, so a password is never
    put back after its app stopped watching it.
- Scope: everything one drop, paste, capture or service call started (an
  "action"); the files of one drop go together.
- Where:
  - The upload's notification ("Uploaded", "Link copied", "Waiting for a
    connection") has Undo, which works for as long as the notification is there.
  - The panel's recent upload row shows Undo next to Copy (never in its
    place) for 10 seconds after the link is copied or the upload ends, and
    while it still uploads.
  - The "Undo the last upload" shortcut, in the same window (a beep otherwise).
  - Cancel on an upload whose link was copied does the same for that file.
- Not for a replace (the old bytes are gone) or a watched folder's files.
- "Upload undone" confirms it (when notifications are on); a file that
  couldn't be deleted (offline) says so and stays in Library.
- Windows: the clipboard is kept format by format (`EnumClipboardFormats`;
  GDI handle and private formats left out, and formats Windows makes from
  others, like `CF_TEXT` next to `CF_UNICODETEXT`), up to 64 MB, and put back
  only if `GetClipboardSequenceNumber` hasn't moved since Aktar's copy. A
  clipboard carrying `ExcludeClipboardContentFromMonitorProcessing` or
  `Clipboard Viewer Ignore`, or `CanIncludeInClipboardHistory` or
  `CanUploadToCloudClipboard` set to 0 (password managers), is never kept.
  The notifications are toasts with a tag (so "Uploaded" replaces "Link
  copied") and an Undo button, which works while Aktar runs.
- Mobile: Undo is on the upload's toast for 10 s, next to Copy in Recent
  uploads, and on its notification (which still works after the app was
  closed, through the upload's history ID). The clipboard is only put back
  for an upload from the clipboard (the text or image that was pasted); for
  any other upload Undo empties it, if it still holds the link: keeping a
  copy would mean reading the clipboard on every upload, which makes iOS ask
  to paste and Android announce it. Whether the clipboard still holds the
  link, and whether a password manager marked it, is read without its
  contents (`clipboardState()` in the app's native module: the iOS change
  count and pasteboard types, the Android clip's timestamp and sensitive
  flag). A clipboard over 24 million characters isn't kept.

## 5. Clipboard text and links

Every clipboard upload (shortcuts, the panel's Paste and ⌘V, per-destination
shortcuts, aktar://upload-clipboard, local API `POST /v1/upload-clipboard`,
Shortcuts "Upload Clipboard"; on mobile the Paste tile, aktar://upload-clipboard
and the Upload Clipboard shortcut, where there are no copied files) reads, in
this order:

1. A copied file (the first one).
2. Image data (PNG, TIFF), as a PNG.
3. A link: the whole text, trimmed, is one http(s) address with a host and no
   spaces, at most 8 KB; or the clipboard's URL type when its text is one line
   (a link copied with its title).
4. Text with something other than spaces in it.

### A copied link

The file it points to is downloaded when the upload starts (the row says
"Downloading the link..."), then uploaded like any file: re-hosting images
and files that might disappear, or temporary CDN links.

- Request: no cookies or cache, 60 s timeout, redirects only to http(s),
  `User-Agent: Aktar/<version> (+https://getaktar.com)`.
- Refused, with a reason: a web page (`text/html`, `application/xhtml+xml`;
  "Copy the link of the image or file itself"), an empty file, a 4xx answer,
  a file bigger than the free disk space minus 2 GB.
- A dropped connection, 5xx, 408 and 429 wait and retry like an upload (part 2).
- Name: Content-Disposition's `filename*` (RFC 5987) or `filename`, else the
  last path segment after redirects (percent-decoded), else `download`. The
  content type's extension is added when the name has none, and replaces one
  of another kind of file (`photo.jpg` served as WebP becomes `photo.webp`);
  generic types (`application/octet-stream`, `text/plain` and the like) keep
  the name's. One safe path segment, at most 120 characters with the extension.
- "Use for" routes by the name guessed from the link before downloading.
- aktar://upload-clipboard's confirmation names the link, since that's what
  gets downloaded.

### Text

Saved as `clipboard-<8 hex>.<ext>`, UTF-8, and uploaded like a file:

- `json` when all of it is a JSON object or array,
- `md` when it looks like Markdown: a fenced code block, or marks adding up to
  two (a heading, a link `[text](url)`, a table, a task item count two; a list
  item or a quote one; `**bold**` and `` `code` `` one),
- `txt` otherwise.

The first line never becomes the name: it could be a password or a secret.

### Charset

Text uploads (`text/plain`, `text/markdown`, `text/csv`) whose bytes are valid
UTF-8 (files up to 16 MB are checked) are sent as
`Content-Type: text/plain; charset=utf-8`, so a browser shows "ğüşiöç" right
instead of guessing another encoding. History keeps the bare type.

## Local API, CLI, Raycast, MCP

- `POST /v1/upload-clipboard` takes text and links too; with nothing usable it
  answers 422 "The clipboard has nothing to upload: no file, image, link or
  text."
- Uploads through the local API wait for the bytes and answer as before (no
  early link, no offline queue).

## QA checklist (Windows)

- Capture: the shortcut, the panel's Capture and the tray's Capture and
  Upload open the snipping bar; area, window, full screen; Esc uploads
  nothing (and nothing copied a few seconds later is taken); Undo afterwards
  puts back what was on the clipboard before the capture, not the snip.
- Instant link, offline and outbox: as on the Mac (turn Wi-Fi off, upload,
  link copied, row waits; Wi-Fi on, it uploads; quit from the tray while it
  waits, start Aktar, it goes on to the same key). Also a 600 MB file from
  another drive (not kept: it only goes on while Aktar runs) and one on C:
  (kept as a link).
- Upload and paste: Notepad, a browser text field, Slack, Windows Terminal;
  a shortcut with Alt (no menu bar opens); Turkish F and Dvorak layouts.
- Undo: the toast's Undo button while it's on screen and from the action
  center, the panel and the shortcut; a password copied from a password
  manager before the upload (the clipboard is emptied, not restored).
- Clipboard: text (txt, md, json), a link to an image, a link to a web page
  (refused), a link copied from Edge's address bar (its title is the text).

## QA checklist (iOS and Android)

- Paste: text (txt, md, json), a link to an image, a link to a web page
  (refused, saying so), a link without an extension; aktar://upload-clipboard
  names the link in its confirmation; the Upload Clipboard shortcut.
- Instant link: a small file (one "Uploaded"), a large video (link right
  away, the toast says "Link copied, uploading..." and then "Uploaded" in
  place), a short link destination.
- Offline: airplane mode, upload, the row waits; back online (and back in
  the app), it goes. Close the app while it waits, open it, it goes to the
  same link. Android: a 600 MB video (not kept; only while the app runs).
- Undo: from the toast, Recent uploads and the notification (also after the
  app was closed); after pasting an image or text (it comes back), after a
  photo from the library (the clipboard is emptied of the link only), after
  copying a password from a password manager (emptied, not restored).
- iOS: no "Aktar would like to paste" prompt appears for uploads that don't
  come from the clipboard.

## QA checklist (Mac)

- Capture: first run asks for Screen Recording; area, window (Space), Esc;
  the sandbox exception (a failure shows the tool's message); Use For routing;
  WebP conversion of a capture.
- Instant link: small file (one "Uploaded"), 1 GB+ file (link right away,
  "Link copied" then "Uploaded"), temporary link destination, short link
  destination (short link copied right away), paths with `{filename}` only
  (link after the name check).
- Offline: turn Wi-Fi off, capture or paste, check the link is copied and the
  row waits; Wi-Fi on, it uploads; quit Aktar while waiting, relaunch, it
  uploads to the same key.
- Upload and paste: TextEdit, Slack, a browser text field, Terminal; Turkish F
  and Dvorak layouts; without Accessibility (link copied, prompt shown once).
- Undo: from the notification, the panel, the shortcut; during a large upload;
  after an image was on the clipboard (it comes back); after copying something
  else (left alone); a reused duplicate (file stays); a password manager copy
  before the upload (clipboard emptied, not restored).
- Clipboard: text (txt, md, json), a link to an image, a link to a web page
  (refused), a link without an extension, Safari "Copy Link".
