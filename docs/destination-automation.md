# Destination routing, replacing files and automation

Shared by the Mac, Windows, iOS and Android apps. Three features, all set per
destination, all carried in a destination transfer (see
destination-transfer.md) except secrets.

## 1. Use for (routing by file type)

`destination.useFor` (optional object, omitted when empty):

```json
{ "kinds": ["image", "video"], "extensions": ["dmg", "zip"] }
```

- `kinds`: any of `image`, `video`, `audio`, `document`, `archive`. Unknown
  values are dropped on decode.
- `extensions`: lowercase, without the dot, trimmed, unique, each 1-16 of
  `[a-z0-9]`. Invalid ones are dropped on decode; the form refuses them.

Kinds by extension (the same lists on every platform, so a file routes the same
way everywhere):

| Kind | Extensions |
|---|---|
| image | png jpg jpeg gif webp avif heic heif tif tiff bmp svg ico cr2 cr3 nef arw dng orf rw2 raf |
| video | mp4 mov m4v avi mkv webm wmv flv 3gp mpg mpeg |
| audio | mp3 m4a aac wav flac ogg opus aif aiff wma |
| document | pdf doc docx xls xlsx ppt pptx key pages numbers odt ods odp rtf txt md csv json epub |
| archive | zip rar 7z tar gz tgz bz2 xz dmg iso pkg |

### When it applies

Only to uploads that would otherwise go to the default destination because no
destination was named: the clipboard shortcut, a drop on the menu bar icon or
tray, the panel, Finder/Explorer menus, the share sheet, Shortcuts/intents and
the local API (and CLI, Raycast) without `destinationId`. An upload to a
destination that was picked (the bucket view, a per-destination shortcut, a
watched folder, `destinationId`) is never rerouted.

### Choosing

For each file, by its extension. A folder dropped as a ZIP routes as a `zip`
file; a folder uploaded with its structure is not split and goes to the
default destination.

1. Destinations whose `extensions` contain the file's extension.
2. Otherwise destinations whose `kinds` contain the file's kind.
3. Otherwise the default destination.

Among several matches at the same step, the default destination wins if it is
one of them, otherwise the first in the destinations list. Each file then
uploads with its destination's own settings (path, copy format, Delete after,
link, metadata, processing, thumbnails, hooks). Files of one drop that land in
different destinations are copied together in drop order, one line each.

The UI says where a file will go: the panel/tray shows "Images and videos go to
Screenshots" style hints under the destination picker when any destination
has `useFor`.

## 2. Per-destination shortcut (desktop) and quick actions (mobile)

- Mac and Windows: each destination can record a global shortcut that uploads
  the clipboard to that destination (like the app's clipboard shortcut, but
  never rerouted). Stored locally only, never transferred.
- iOS Home Screen quick actions and Android app shortcuts: one per destination
  (up to 4, default destination first), "Upload to <name>", opening the
  picker with that destination chosen.

## 3. Replace file (keep the link)

Replacing writes a new file to the exact key of an existing upload or bucket
object, so its link keeps working.

- Available in History/Library (a record's menu and details), the bucket view
  (an object's menu and details), the local API and the CLI, and on mobile in
  the upload and object details.
- The new file gets the destination's metadata removal and resize, but never a
  format conversion: the key's extension stays, and the content type is the
  new file's. Content-Disposition follows the usual rules for the key.
- The key never gets numbered and a multipart upload is used above the normal
  threshold. A replaced expiring file (under `tmp/{N}d/`) starts its N days
  again; the history entry's expiry moves accordingly.
- History: the entry keeps its ID, key and link; its size, content hash,
  content type and thumbnail are updated, and `replacedAt` is set (shown as
  "Replaced <date>"). The original upload date stays.
- Thumbnails: made again from the new file; in bucket mode saved over the old
  one; otherwise the bucket thumbnail at that key (any thumbnail folder of the
  bucket) is deleted.
- Reuse links for duplicate files: a replaced entry is matched by its new hash.
- Then the cache steps below, then the destination's hooks with
  `"event": "upload.replaced"`.

### Cache

Two independent per-destination settings:

- `shortCache` (bool): every upload to the destination (and every replace) is
  sent with `Cache-Control: public, max-age=60`, so a replaced file shows up
  everywhere within about a minute, without any extra setup.
- Cloudflare purge: `cloudflareZoneId` (string, transferred) plus an API token
  (secret, stored with the destination's keys, transferred only inside the
  encrypted credentials as `cloudflareToken`). After a replace, POST
  `https://api.cloudflare.com/client/v4/zones/{zone}/purge_cache` with
  `{"files": [<public URL>]}` and `Authorization: Bearer <token>`. A failure
  doesn't fail the replace; it's reported ("The file was replaced, but
  Cloudflare's cache couldn't be cleared: ..."). The form has Check, which
  calls `GET /client/v4/user/tokens/verify`. The token needs only
  Zone > Cache Purge.
- Watched folders that replace their upload so the link stays use the same
  two settings.

## 4. Hooks after upload (per destination)

`destination.hooks`: the same list as a watched folder's Automation
(`{"kind": "webhook"|"script", "target": "..."}`), run after every upload to
the destination that isn't from a watched folder (those run their folder's
own Automation), after a replace, and not for reused duplicate links.

- Webhook: POST JSON, 10 seconds, https (http only for localhost and private
  networks), no redirects to another host. Every platform.
- Script: Mac (Application Scripts folder) and Windows (scripts folder), with
  the JSON on stdin and link, key, file, destination as arguments. Not on
  mobile.
- Payload: the watched-folder payload (same field names), with `event`
  `"upload.succeeded"` or `"upload.replaced"`, a new `destination`
  object (`{"id", "name"}`), and no `folder` object for manual uploads.
  A script's fourth argument is the destination's name instead of the
  folder's.
- A failing hook is reported once per destination per minute and never fails
  the upload.

## 5. Automation entry points

- Mac and iOS: App Intents (Shortcuts, Spotlight, Siri):
  - Upload File (files, optional destination, optional name, optional Delete
    after) returns the links (and the copied text as a second output).
  - Upload Clipboard (optional destination).
  - Replace File (an upload, a file) returns the link.
  - Get Recent Uploads (count, optional destination) returns uploads with
    their links.
  - Destination is an app entity (name, ID). Uploads from an intent follow
    routing when no destination is given.
- Android: an exported activity for `com.getaktar.mobile.action.UPLOAD`
  (EXTRA_STREAM, optional `destination` name or ID, optional `name`) that
  uploads without showing the app, and a broadcast
  `com.getaktar.mobile.action.UPLOADED` (extras `link`, `url`, `key`,
  `destination`) after every upload, for Tasker, MacroDroid and the like.
  The result is also returned with `setResult` for callers that start it for
  a result.
- Windows: the CLI and local API are the automation surface; documented with
  Power Automate and Task Scheduler examples.
- Local API additions: `useFor`, `shortCache`, `hasCloudflarePurge` and
  `hooks` count in the destination DTO;
  `POST /v1/uploads/{id}/replace` and
  `PUT /v1/destinations/{id}/objects?key=` (raw file bytes, returns the
  upload) for replacing. CLI: `aktar replace <upload id | link | key> <file>`.

## Transfer payload

New optional destination fields: `useFor`, `shortCache`, `cloudflareZoneId`,
`hooks` (webhooks only are applied on mobile; scripts are kept but shown as
"script, runs on Mac and Windows"). New optional credential field:
`cloudflareToken`. Shortcuts are never transferred. Decoding stays lenient:
invalid parts are dropped, never failing the import.
