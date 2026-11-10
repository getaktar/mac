# Share pages, galleries, text pages, file requests and encrypted links

A sharing layer that lives entirely in the user's own bucket: Aktar writes a
small static HTML page next to the upload, and that page is what's shared. No
server, nothing hosted by Aktar. Shared by the Mac, Windows, iOS and Android
apps; the Mac app is the reference.

| Part | Mac | Windows | iOS | Android |
|---|---|---|---|---|
| 1. Share page (one file) | yes | yes | yes | yes |
| 2. Gallery (one link for many files) | yes | yes | yes | yes |
| 3. Text page | yes | yes | yes | yes |
| 4. File request (others upload to you) | yes | yes | yes | yes |
| 5. Encrypted links (end to end) | yes | yes | yes | yes |

Background and evidence: the 2026-11-09 feature research (resources folder,
`ozellik-arastirmasi-2026-11-09.md`). Dropshare has landing pages and upload
encryption; nobody free and cross-platform does.

## The page itself

Every page is `docs/share-page/template.html`, filled in. **Each app ships a
byte-for-byte copy of that file** (Mac: a bundle resource; Windows:
`include_str!`; mobile: a generated TS string). Changing the page means
changing it here and copying it everywhere; `node docs/share-page/test.mjs`
must pass. `docs/share-page/reference.mjs` is the reference implementation of
everything in this section and in "Encrypted links": port it, don't
reinterpret it.

Filling it: replace, each exactly once and in this order,

1. `{{LANG}}`: the app's UI language code (`en`, `tr`, `pt-BR`, `zh-Hans`, ...), HTML-escaped.
2. `{{TITLE}}`: the page title (below), HTML-escaped.
3. `{{META}}`: the head tags (below), one per line.
4. `{{DATA}}`: the page data as JSON, escaped for a script element.

HTML escaping: `& < > " ' { }` become `&amp; &lt; &gt; &quot; &#39; &#123; &#125;`.
JSON escaping: normal JSON, then `<` `>` `&` U+2028 U+2029 become `<`
`>` `&` ` ` ` `. Because braces are escaped in 1-3 and
the data goes in last, nothing put in can be mistaken for a placeholder, and
nothing in the data can end the script element.

The page renders everything itself from the data (text with `textContent`,
links only if http/https/blob), shows its UI in the visitor's browser
language (17 languages, built in), and has a strict CSP in a meta tag. It is
uploaded with `Content-Type: text/html; charset=utf-8` and **no**
`Content-Disposition` (it must open in the browser). This is the one place
Aktar writes HTML that opens inline: files users upload keep their
`attachment` rule (HTML, SVG, XML, JS), and the page never embeds those (no
iframe, only a download button). The page must not be cached for long: send
`Cache-Control: public, max-age=60` (it's rewritten on Replace File).

### Data (`{{DATA}}`, version 1)

```json
{
  "v": 1,
  "kind": "file | gallery | text | encrypted | request",
  "lang": "tr",
  "created": "2026-11-09T12:00:00Z",
  "expires": "2026-11-16T12:00:00Z or null",
  "files": [{ "name": "a.png", "url": "https://...", "size": 123, "type": "image/png", "thumb": "https://... or null" }],
  "text": "for kind text",
  "syntax": "swift (for kind text, or null)",
  "encrypted": { "url": "https://...", "size": 4567, "password": false },
  "request": { "title": "", "note": "", "maxBytes": 2000000000, "conditional": true, "slots": [{ "file": "https://presigned PUT", "meta": "https://presigned PUT" }] },
  "brand": false
}
```

- `created`: ISO 8601 UTC, when the page was written.
- `expires`: the earliest of the upload's Delete after date and, for a
  temporary link, when its signature runs out; for a request, when it closes.
  Null when nothing expires. The page shows "Available until ..." and, once
  past, "This link has expired."
- `files[].url`: what the browser loads. Public destinations: the public URL.
  Temporary-link destinations: a presigned GET for the same duration as the
  page's own link (they're signed together, see "Temporary links").
- `files[].thumb`: the bucket thumbnail's URL when the destination keeps
  thumbnails in the bucket and one was made (thumbnails.md), else null.
- `files[].type`: the Content-Type the file was uploaded with.
- `brand`: omitted (true) shows a small "Shared with Aktar" footer link.
  There's no setting for it in v1; leave it out.

### Head (`{{TITLE}}`, `{{META}}`)

Exactly as `headFor` in `reference.mjs` (order matters only for tests):

- `<meta name="description">`, `og:title`, `og:description`, `og:type`
  (`video.other` for an mp4/webm video, else `website`), `og:image` +
  `og:image:alt` when there's an image, `og:video` + `og:video:secure_url` +
  `og:video:type` for mp4/webm, `twitter:card` (`summary_large_image` with an
  image, else `summary`), `twitter:title`.
- Title: the file name; a gallery: `<first name> +<n-1>`; encrypted:
  `Encrypted file`; a request: its title or `Send files`.
- Description: `2.4 MB · PNG` (decimal units, one decimal below 100: see
  `formatSize`); a text page: the first 200 characters of the text,
  whitespace collapsed; a gallery: `3 files · 4.1 MB`; encrypted:
  `Open the link to decrypt it in the browser.`; a request: its note's first
  200 characters or `Upload files straight to the requester's storage.`
  These head strings are English on purpose (crawlers have no language).
- og:image: the file itself for images up to 8 MB except SVG and HEIC (crawlers
  don't render those); otherwise the bucket thumbnail when there is one;
  otherwise none. Gallery: the first file that has one. Never for encrypted
  files (that would leak them).

## 1. Share page (one file)

Per destination: **Share Page**, off by default. The JSON key is `sharePage`
(`true`, absent is off) in destinations.json / the Mac settings model, and in
the destination transfer payload (destination-transfer.md: optional key,
older apps ignore it; check that each decoder really ignores unknown keys).

Setting copy (en): "Share Page" / "Copies a link to a page with a preview and
a download button, written next to the file in your bucket. Slack, Discord,
iMessage and X show a card for it." Localize with the app's other strings.

With it on, every upload to the destination (except the ones listed below)
also writes a page:

- **Key:** the upload's key plus `.html` (`2026/11/x7Kp2.png` ->
  `2026/11/x7Kp2.png.html`). It's under the same `tmp/{N}d/` prefix as the
  file, so Delete after removes both. It's written with a plain PUT after the
  file is up (not conditional: the file key was free, so this one is too).
- **The link that's copied** is the page's URL instead of the file's. The
  output formats ("Copy as") use it like this:
  - URL: the page link.
  - Markdown / HTML: images, videos and audio keep the **file** link (they're
    embedded); everything else gets the page link.
  - Custom: `{url}` is the page link; a new `{file}` variable is the file
    link (also add `{file}` to the variables help).
  - The shortener shortens the page link (short-links.md rules unchanged).
- **History:** the record gets `sharePageKey` (the page's key). The Library
  shows the page link as the main link, plus "Copy File Link" (and the
  existing Copy Temporary Link copies a temporary link to the **file**).
  An upload without a page has no `sharePageKey` and behaves as today.
- **Delete / Undo / Delete after / watched-folder delete:** the page goes with
  the file, if no other history record has the same `sharePageKey`
  (galleries). Missing pages are not an error.
- **Replace File:** the file is replaced as today, then the page is written
  again at the same key (new size, date), and the page URL is added to the
  Cloudflare purge.
- **Duplicate reuse** (same bytes uploaded again): the earlier record's link
  is reused as today; if that record has a page, its page link is copied.

Not given a page: watched-folder uploads (they have their own copy rules),
files of a folder uploaded with its structure (they get a gallery when the
folder is dropped, see 2), uploads made through the local API / Shortcuts /
App Intents / CLI unless they pass `page=1` (keep the API unchanged in v1:
no page there), and Replace File of an upload that had no page.

Instant link (capture-and-instant-links.md, part 2): with a share page, the
copied link is the page's, and the page is written right after the file.
Until then the page URL returns 404, exactly like the file's would; the
existing "still uploading" notice covers it. Nothing else changes.

### Warnings in the destination form

Show these under the toggle when it's on (and under Encryption, part 5):

- The public base URL is on `*.r2.dev`: "r2.dev links are rate limited and
  some filters block HTML pages on them. A custom domain works better."
- The bucket is reached path-style (the public base URL's path starts with
  `/<bucket>`, as with MinIO or B2's friendly URLs): "Pages here share one
  web address with everything else on this server." For encryption (part 5)
  this one is stronger: "Encrypted links need their own domain (or
  virtual-hosted URLs) to be safe here." Still allowed.

### Temporary links

A destination with "Copy a temporary link" signs the page URL for that
duration; the page's `files[].url` (and `thumb`, and for encrypted the blob
URL) are presigned GETs with the same duration, made at the same moment.
`expires` is when they run out. Copy Temporary Link from the Library copies a
temporary link to the file (pages can't be re-signed without rewriting them).

## 2. Gallery (one link for many files)

When share pages are on and several files are uploaded together (one drop,
one paste of several files, one Share sheet, or a folder uploaded with its
structure), they get **one** gallery page and **one** link instead of a link
per file:

- Each file is uploaded as today, without its own page.
- When the group is done (the existing "copy links together once the last is
  done" point), the gallery page is written with every file that made it, in
  group order, and its link is copied (formatted as URL; Markdown/HTML/custom
  formats copy the gallery link as a plain link: `[<first> +N](url)` for
  Markdown, `<a href>` for HTML).
- **Key:** the first successful file's key plus `.gallery.html`.
- Every record of the group stores the gallery key as `sharePageKey`.
  Deleting a record removes its file; the gallery page is deleted with the
  last record that points to it. (The gallery keeps listing deleted files;
  their tiles just fail to load. Rewriting it is not needed in v1.)
- A file that fails and is retried later copies only its own link (as today)
  and isn't added to the gallery.
- A single file is never a gallery. A folder uploaded as a ZIP is one file.
- The page zips the files in the browser for "Download all" up to 1 GB in
  total; above that, files are downloaded one by one.
- Undo of the group removes the files and the gallery page.

## 3. Text page

When share pages are on and the upload is text, the page is kind `text`: the
text is embedded in the page (escaped, highlighted in the browser) with Copy
Text, Download and Wrap buttons.

- Text means: clipboard text uploads (capture-and-instant-links.md part 5),
  and files whose Content-Type is `text/*`, `application/json`,
  `application/xml`, `application/javascript`, `application/x-sh`,
  `application/x-yaml` or `application/toml`, **and** whose size is at most
  256 KB, **and** whose bytes are valid UTF-8. Anything else is kind `file`.
- `syntax`: from the extension, lowercase, one of: swift, kotlin, java, js,
  ts, jsx, tsx, json, python, ruby, go, rust, c, cpp, csharp, php, shell,
  bash, zsh, powershell, sql, html, css, scss, xml, yaml, toml, ini, markdown,
  dockerfile, makefile, r, perl, lua, dart, scala, elixir, text (`.txt`,
  `.log`, `.csv` and anything unknown are `text`). Map file names
  `Dockerfile` and `Makefile` too.
- Clipboard text has no extension: `.txt` (or `.md` as today), `syntax` text
  or markdown.

## 4. File request (others upload to you)

"Request Files" makes a link where anyone who has it can send files straight
into the bucket, until it expires. The app collects what arrives and runs it
through the normal upload of that destination (so naming, Delete after,
thumbnails, image processing and short links all apply), then deletes the
temporary copy.

### Creating one

Entry points: Mac menu bar panel (More menu) and Library ("Requests" list);
Windows panel and Library; mobile: a "Request files" action on the home
screen's menu and a Requests list. One sheet/dialog:

- Destination (default: the default destination).
- Title (optional, shown big on the page, 100 chars), Note (optional,
  1000 chars).
- Valid for: 1 hour, 1 day (default), 7 days. 7 days is the maximum (SigV4
  presigned URLs can't live longer).
- Up to: 1, 5, 10 (default), 20 files.
- Size limit per file: 100 MB, 1 GB, 2 GB (default), 5 GB. The page enforces
  it; the bucket can't (see "Limits").

Then the app:

1. Makes an ID: 10 random characters from `[0-9A-Za-z]`.
2. Sets up CORS when the browser will upload to another origin (below).
3. Presigns, for slots `i = 1..N`, two PUT URLs with the request's duration:
   `.aktar/requests/<id>/<i>` with signed header `content-type:
   application/octet-stream`, and `.aktar/requests/<id>/<i>.json` with
   `content-type: application/json`. When the provider does conditional
   writes (`ShortKeys.usesConditionalWrites`: Amazon S3 and Cloudflare R2),
   also sign `if-none-match: *`, and set `conditional: true` in the data.
   (Sign `host` as always. The page sends exactly these headers.)
4. Writes the page (kind `request`) at `.aktar/requests/<id>/index.html`,
   `expires` = now + duration.
5. Copies its link (public URL of the page; a temporary-link destination
   signs it for the duration), shows it with Copy and QR.

The request is saved locally (not in the bucket, not transferred):
`requests.json` next to destinations (Mac: Application Support/Aktar), a list
of `{ id, destinationId, title, note, createdAt, expiresAt, slotCount,
maxBytes, link, received, closedAt }`. Requests made on another device
aren't known here.

### CORS

The page is served from the public base URL (or, on a temporary-link
destination, from the S3 endpoint itself). The PUTs go to the S3 endpoint.
If those origins differ, the bucket needs a CORS rule:

- AllowedOrigins: the page's origin (`https://cdn.example.com`).
- AllowedMethods: `PUT`. AllowedHeaders: `content-type`, `if-none-match`.
  ExposeHeaders: `etag`. MaxAgeSeconds: 3600.

`GetBucketCors`, keep every other rule, add or replace this one (matched by
ID `aktar-file-requests`, or by the same origin + PUT when the provider drops
IDs), `PutBucketCors`. Once per destination and origin; remember it in the
destination (`requestCorsOrigin`, not transferred) and redo it if it fails
later. If the provider refuses (MinIO has no bucket CORS; a key without the
permission), show: "This bucket doesn't let browsers upload to it. Allow PUT
from <origin> in its CORS settings, then try again." with the rule as JSON
to copy, and don't create the request.

### Collecting

While a request is open (until `expiresAt` + 1 hour) the app checks it: at
launch, every 2 minutes while running (mobile: when the app comes to the
foreground and every 2 minutes while it's in front), and on "Check Now".

1. List `.aktar/requests/<id>/` (recursive).
2. For each slot `<i>` with an object: wait until `<i>.json` exists too, or
   until the object is 10 minutes old (then the name is `upload-<i>`).
3. Read `<i>.json` (max 4 KB): `{ v, name, type, size, sent }`. Sanitize the
   name: last path component only, no control characters or `/ \ :`, at most
   200 characters, never empty (`upload-<i>`). Ignore `type` (the
   destination decides the Content-Type from the extension, as for any
   upload, including the attachment rule for HTML/SVG/...).
4. Download the object to a temporary file (respect `maxBytes` + 1 MB; a
   bigger one is deleted unread), then upload it to the request's
   destination like a dropped file with that name, except: no link is
   copied, no paste, no per-file notification, no share page. The history
   record's source label is "Request: <title>" (or "Request").
5. When it's in history, delete `<i>` and `<i>.json`, bump `received`.
6. One notification per check that found files: "Received 3 files" with the
   request's title; clicking opens the Library filtered to them (or just the
   Library).

After `expiresAt` + 1 hour and a last check, delete what's left under the
prefix (including `index.html`), set `closedAt`. "Close Now" does the same
immediately (the link stops working at once). Deleting the destination
closes its requests.

### Limits (say these in the sheet's footer)

- "Anyone with the link can send files until it expires."
- The size limit is enforced by the page, not the bucket: a determined sender
  could put up to 5 GB per slot. Slots and the short lifetime bound it.
- Without conditional writes (MinIO, B2, DigitalOcean, other S3), two people
  sending at the same time can overwrite each other: show "On this provider a
  request link is meant for one sender." under the destination picker.
- Files sent after the app last ran stay in `.aktar/requests/` until it runs.

## 5. Encrypted links (end to end)

Per destination: **Encryption**: Off (default), "Key in the Link", "Ask for a
Password". JSON key `encryption`: `"link"` or `"password"` (absent is off),
also in the transfer payload.

Setting copy (en): "Files are encrypted on this device before they're
uploaded. The link opens a page that decrypts them in the browser; your
storage provider only ever sees noise." / Key in the Link: "Anyone with the
link can open the file." / Ask for a Password: "Aktar asks for a password
for each upload. Share it separately; the link alone doesn't open the file."

An encrypted upload:

1. The file goes through the usual processing first (image processing,
   metadata removal), on its plaintext.
2. **Key** (ignores the path template: names and extensions would leak):
   `<expiry prefix>e/<22 random [0-9A-Za-z]>` for the encrypted file, plus
   `.html` for its page. The page is always written, whatever Share Page
   says.
3. Key material:
   - Key in the Link: 32 random bytes. Link: `<page URL>#k=<base64url, no
     padding>`.
   - Password: ask before the upload (a small prompt like Rename; empty or
     cancelled = the file isn't uploaded). 16 random salt bytes, key =
     PBKDF2-HMAC-SHA256(NFC UTF-8 password, salt, 600 000 iterations, 32
     bytes). Link: `<page URL>` (no fragment). Non-interactive uploads to a
     password destination (watched folders, local API, Shortcuts, request
     collection) use Key in the Link instead, and say so in the setting's
     description.
4. Encrypt to a temporary file in the format below; upload it with
   `Content-Type: application/octet-stream` (no Content-Disposition), then
   the page (kind `encrypted`, `encrypted.url` = the blob's URL,
   `encrypted.size` = its length, `encrypted.password`).
5. The link is never formatted (always a plain URL, whatever "Copy as"
   says). Shortening: shorten the URL **without** the fragment, then append
   the fragment to the short link (browsers keep a fragment across
   redirects); the key is never sent to the shortener.
6. History: `encryptionKey` (base64url of the raw or derived 32-byte key)
   and `encryptionSalt` (hex, password mode) are stored in the record, so
   Replace File can keep the link: it re-encrypts with the same key (and
   salt, iterations) and a new random nonce prefix, overwrites the blob and
   rewrites the page.
7. Never for encrypted uploads: bucket thumbnails (local ones are fine),
   og:image, duplicate reuse, instant link (the link is copied when the
   upload is done), galleries (several files dropped together are each
   encrypted on their own; their links are copied one per line), the text
   page's plaintext (text is encrypted like any file; the page shows it
   after decryption, with `syntax` from the metadata).

### Format (version 1)

All integers big-endian. `docs/share-page/vectors.json` has test vectors
(made by `test.mjs`); every app's unit tests must reproduce them byte for
byte (sha256 of the output) and decrypt them.

```
header (42 bytes)
  0   4  "AKE1"            41 4B 45 31
  4   1  version           1
  5   1  kdf               0 = key in the link, 1 = PBKDF2-HMAC-SHA256 password
  6   4  iterations        0 for kdf 0; 600000 when written (readers accept 100000...10000000)
  10  16 salt              zeros for kdf 0
  26  8  nonce prefix      random per file (and per Replace File)
  34  4  record size       65536 (plaintext bytes per content record)
  38  4  metadata length   ciphertext length of record 0 (plaintext + 16)
record 0: metadata, record 1...n: content
  nonce = nonce prefix (8) || index (u32)
  AAD   = header (42 bytes) || final (1 byte: 1 for the last content record, else 0)
  sealed = AES-256-GCM(key, nonce, AAD, plaintext) || tag (16)
metadata plaintext: UTF-8 JSON {"name":"...","type":"...","size":N} (+ "syntax" for text)
content: the file in 65536-byte records, the last one shorter; an empty file is one
  empty final record; record 0 is never final
```

Total length = 42 + (metadata JSON + 16) + size + 16 x max(1, ceil(size / 65536)).
Encrypt and decrypt streaming (record by record), never the whole file in
memory. The page refuses truncated files (no final record), reordered or
altered records (the AAD and nonce bind them), and a size that doesn't match
the metadata.

Platform crypto: Mac CryptoKit `AES.GCM` + CommonCrypto PBKDF2 (as
DestinationTransfer); Windows the `aes-gcm` and `pbkdf2` crates already in
Cargo.toml; mobile `expo-crypto`'s AES-GCM (as the transfer codec) and
`@noble/hashes` `pbkdf2Async` (600 000 iterations take a few seconds on a
phone: show progress in the password prompt).

## Testing

- `node docs/share-page/test.mjs` (template, reference, vectors).
- Each app: unit tests for filling the template (escaping, head tags, data
  JSON for each kind), the encryption vectors, page/gallery key rules, the
  request collection's name sanitizing and slot pairing, and the CORS rule
  merge. Integration tests against MinIO where the app has them (Mac
  `scripts/test-integration.sh`, Windows live tests): page written next to
  the file, deleted with it; request slots presigned, a PUT with the signed
  headers accepted, a PUT with another Content-Type refused (403), collection
  moves the file into history.
- Device QA (not possible here): Slack/Discord/iMessage/X cards for a page on
  a custom domain, decrypting a 1 GB file in Safari and Chrome, a request
  link opened on a phone.

## Decisions made while building the Mac app

Where the spec above left a choice, the Mac app (the reference) does this;
the ports follow it.

- **Filling the template:** every value is inserted literally.
  `reference.mjs` used string replacements for `{{LANG}}` and `{{TITLE}}`,
  which JavaScript reads as patterns (`$&`, `$'` in a file name pulled the
  placeholder or the rest of the template in); it now passes functions, like
  `{{META}}` and `{{DATA}}`. Ports that use a plain string replace are fine.
- `lang`: the app's UI language (Mac: the first of the bundle's preferred
  localizations).
- `files[].type` is the bare MIME type (`text/plain`, no `; charset=...`),
  and so is the encrypted metadata's `type`. The metadata's `syntax` is
  written for text types only, and left out when it would be `text`.
- **Galleries** are made only when every file of the group goes to one
  destination that has Share Page on and no encryption. Several files
  dropped on such a destination form the group (before, each copied its own
  link). A drop that "Use for" splits across destinations copies links one
  per line, as before. Several files to an encrypting destination are grouped
  too, so their links are copied together, one per line.
- A gallery group where only one file made it gives that file its own page
  (`kind: file`, `<key>.html`) and copies that link. Files of the group that
  reused an earlier upload's link are listed in the gallery, but their records
  keep their own `sharePageKey`. "Copy as" Custom copies a gallery as its
  plain URL.
- **Which uploads are encrypted:** uploads to a key Aktar makes. A folder
  goes to an encrypting destination as a ZIP (the key ignores the path, so
  its structure can't be kept). An upload to an exact key (bucket browser,
  local API `prefix=`) is not encrypted, unless it writes over an encrypted
  upload (Replace File, a watched folder keeping its link): that re-encrypts
  with the upload's own key and salt and rewrites its page.
- An encrypted record's `byteSize` is the encrypted file's length (what's in
  the bucket, which watched folders compare); its `contentHash` is empty, so
  it's never reused. The Library shows only the local thumbnail for it,
  opens its page, and doesn't offer Copy Temporary Link (the file alone is
  noise). The local API's `url` for it is the page link with its key.
- **Failures:** an encrypted upload whose page can't be written deletes the
  encrypted file and fails (it can't be opened without the page). A plain
  upload whose page can't be written copies the file's own link and says so.
- **Password prompt:** one per file, before it's queued, with a second field
  to repeat the password; a mismatch asks again.
- **Temporary links** with an instant link: the page link is signed when
  it's copied, the file's (in the page data) when the page is written.
- **File requests:** CORS is set up when the page's origin differs from the
  upload origin and `requestCorsOrigin` isn't that origin already. When the
  bucket refuses, the sheet shows the message and the rule as JSON with Copy
  Rule and "I Added the Rule" (for a key that can't read or write CORS: it
  records the origin and creates the request). `requestCorsOrigin` is
  cleared when the endpoint, bucket, region, public base URL or temporary
  link setting changes.
- Collected files go through the destination's upload as an unattended
  upload: no copied link, notification, share page, hooks or Undo; an
  encrypting destination seals them with the key in the link. A name cut to
  200 characters keeps an extension of up to 16 characters.
- Close Now (and the close after the last check) deletes `index.html` first,
  then the rest of the prefix. Removing a destination closes its requests
  and empties their prefixes in the background, with its keys as they were.
- The Requests list shows open requests first; a closed one can be removed
  from the list.

## Not in v1

Per-upload choice of page or no page in the panel, rewriting a gallery when
one of its files is deleted, page themes or branding settings, password
protection without encryption (impossible without a server), request links
made by the CLI or local API, receiving files into an encrypted destination
encrypted (they're collected and then uploaded as the destination says).
