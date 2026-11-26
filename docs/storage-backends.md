# Storage backends

Aktar uploaded only to S3-compatible storage until 0.22.1. This spec adds
other kinds of destinations, starting with WebDAV, then SFTP. The Mac and
the desktop app (Windows and Linux) follow it the same way, so
destinations.json, the Keychain / keyring entry and QR transfers stay
interchangeable.

## Phases

0. Shipped in Mac 0.22.1 and desktop 0.16.1: destinations.json is read one
   destination at a time, and one this version can't read is kept as raw
   JSON and written back on save.
1. A storage backend layer with S3 as its only backend. Nothing changes
   for users.
2. WebDAV.
3. SFTP.
4. QR transfer format 2, local API `kind`, CLI and Raycast, ShareX import,
   the site.

## The destination's kind

The kind is told by `preset`, not by a new field. New preset values:

| preset | kind | display name |
|---|---|---|
| `cloudflareR2`, `amazonS3`, `minIO`, `backblazeB2`, `digitalOceanSpaces`, `customS3` | `s3` | as before |
| `webdav` | `webdav` | WebDAV |
| `sftp` | `sftp` | SFTP |

Why not a `kind` field: Mac 0.22.1 and desktop 0.16.1 skip fields they
don't know, so a WebDAV destination with a `kind` field and an S3 preset
would load there as an S3 destination and fail on every upload. An
unknown preset makes it unreadable to them, so it's kept untouched (phase 0).

The S3-shaped fields stay required in the JSON, so every destination has
the same shape:

| field | S3 | WebDAV | SFTP |
|---|---|---|---|
| `endpoint` | S3 endpoint | server URL including the base path, e.g. `https://cloud.example.com/remote.php/dav/files/me/aktar` | `host` or `host:port` |
| `bucket` | bucket | `""` | base folder on the server, e.g. `/var/www/files` |
| `region` | region | `""` | `""` |
| `forcePathStyle` | as before | `false` | `false` |
| `publicBaseURL` | as before | the URL a file's key is appended to for its link | same |
| `objectPathTemplate` | as before | same | same |

Credentials keep the same JSON (`StorageCredentials`): for WebDAV and SFTP
`accessKeyId` holds the user name and `secretAccessKey` the password (or,
for SFTP, the private key in OpenSSH format; phase 3 decides). Short link
and Cloudflare tokens stay where they are.

## Capabilities

Each kind declares what it can do. Code asks the destination, not the
preset.

| capability | s3 | webdav | sftp | what needs it |
|---|---|---|---|---|
| `upload`, `delete`, `exists`, `publicURL` | yes | yes | yes | every upload, Undo, duplicate reuse, numbered keys |
| `list` | yes | yes (PROPFIND) | yes | bucket browser, library, file requests collection, thumbnail cleanup |
| `copy` (move, rename) | yes | yes (COPY/MOVE) | yes (rename) | bucket browser, local API move |
| `conditionalWrites` | R2 and Amazon S3 only | no | no | short keys (falls back to `exists`, as for MinIO today) |
| `multipart` | yes | no (one PUT, streamed) | no (streamed) | files over 64 MB, resume |
| `temporaryLinks` | yes | no | no | Link: 5 min ... 7 days, Copy Temporary Link |
| `expiryRules` | yes | no | no | Delete after |
| `fileRequests` | yes | no | no | Request Files |
| `bucketThumbnails` | yes | yes | yes | thumbnails "In the Bucket" |
| `sharePages` | yes | yes | yes | share pages, galleries, encrypted links (they're files next to the file) |
| `cloudflareSetup` | R2 only | no | no | Set Up Cloudflare R2 |

Where a capability is missing, the control is hidden (Link, Delete after,
Request Files) rather than shown and failing. A setting saved for it (say
`expiryDays` on a destination later switched to WebDAV) is ignored.

## The backend interface (phase 1)

One interface on each platform, with S3 as the only implementation for now:

- `testConnection() -> ConnectionResult`
- `upload(file, key, contentType, progress, onlyIfNew) -> UploadResult`
- `put(data, key, contentType)` (share pages, thumbnails, small files)
- `get(key) -> data` (small files: requests, share page reads)
- `delete(key)`, `delete(keys)`
- `exists(key) -> bool`, `info(key) -> size, lastModified`
- `list(prefix, continuation) -> listing`, `listRecursively(prefix)`
- `copy(from, to)`, `createFolder(prefix)`
- `publicURL(key) -> URL`

S3-only operations (presigned URLs, lifecycle rules, CORS, multipart
sessions) stay on the S3 type. Callers that need them check the
capability and then use the S3 type directly.

Construction goes through one factory (`StorageBackends.make(config,
credentials)` on the Mac, `storage::backend(&config, &credentials)` in
Rust) instead of `S3Provider(...)` at each call site, so phase 2 only adds
a case there.

## Compatibility

- A non-S3 destination in an older version: unreadable there, kept as it
  is (0.22.1 / 0.16.1 and later). Older than that, the whole file can't be
  read: that's why phase 0 shipped first.
- QR transfer: a non-S3 destination is sent with format version 2, which
  older versions turn down with "needs a newer version of Aktar". S3
  destinations keep version 1, so transfers between new and old copies
  keep working for them.
- Local API: `DestinationDTO` gains `kind` (`s3`, `webdav`, `sftp`).
  Endpoints a kind can't serve answer 409 with a message saying so.

## WebDAV (phase 2)

Preset `webdav`, display name "WebDAV". It works with any WebDAV server:
Nextcloud and ownCloud (`https://host/remote.php/dav/files/<user>/<folder>`),
Synology, Hetzner Storage Box, Apache `mod_dav`, nginx with the DAV module,
`rclone serve webdav`.

Fields in the form: **Server URL** (`endpoint`: the folder uploads go
into, with its path), **User name** and **Password** (`accessKeyId`,
`secretAccessKey`), **Public Base URL** and the path template as for S3.
Bucket, region, access keys and path style are hidden. `https://` is
required except for `localhost`, `127.0.0.1` and `::1`.

Requests, with Basic authentication (`Authorization: Basic`) on each:

| operation | request |
|---|---|
| upload | `MKCOL` each missing parent folder (201, or 405 when it exists), then `PUT <endpoint>/<key>` streamed with `Content-Type` and, where the destination sets it, `Cache-Control` |
| put (pages, thumbnails) | same as upload, from memory |
| get / download | `GET` |
| delete | `DELETE` (404 counts as done) |
| exists / info | `HEAD` (200: size from `Content-Length`, date from `Last-Modified`; 404: missing) |
| list | `PROPFIND` with `Depth: 1` on the folder, asking for `resourcetype`, `getcontentlength`, `getlastmodified`; the folder's own entry is left out; no continuation (one page) |
| listRecursively | `list` on each subfolder in turn (servers often refuse `Depth: infinity`) |
| copy | `COPY` with `Destination: <absolute URL>` and `Overwrite: T`, after `MKCOL` of the target's parents |
| createFolder | `MKCOL` with parents |
| publicURL | `publicBaseURL` + key, exactly as for S3 |

Keys map to URLs by percent-encoding each `/`-separated segment (RFC 3986
unreserved characters stay). Hrefs in a `PROPFIND` answer can be absolute
URLs or absolute paths, encoded or not: decode them, strip the endpoint's
path, and the rest is the key. A trailing `/` or a `collection`
resourcetype marks a folder.

Redirects are not followed for `PUT`, `MKCOL`, `COPY`, `DELETE` (a 3xx is
an error that names the new location), so credentials never go to another
host.

**Test Connection** for WebDAV: `PROPFIND Depth: 0` on the endpoint (401
means wrong user name or password, 404 means the folder doesn't exist,
other errors as they come), then the same test upload, public link check
and delete as for S3, with the same result lines.

Errors have their own WebDAV wording, since the S3 messages talk about
access keys and buckets: 401 is "wrong user name or password", 403 "not
allowed to write here", 404 on the endpoint "folder not found", 507 "the
server is out of space"; other statuses are shown with their code. 5xx
(except 507) and 429 are retried with the same backoff as S3.

Capabilities for WebDAV: as the table above. Delete after, temporary
links and Request Files are hidden. Files of any size go in one streamed
`PUT` (no 64 MB limit, no resume).

**QR transfer**: a WebDAV destination is sent with format version 2:
both the envelope's first byte and the payload's `v` are 2, so an older
app turns the link down before asking for the code. The AAD stays
`aktar-transfer-v1`. The payload is the same JSON; `bucket` and `region`
are empty or missing. S3 destinations keep version 1, and a receiver that
knows version 2 accepts both.

**Local API**: `DestinationDTO.kind` (`s3`, `webdav`) next to `provider`
(the preset, `webdav`).

New UI strings ("WebDAV", "Server URL", "User name", "Password",
"Folder not found", the https rule, the out of space message and any
other) are added in all 17 languages (en, tr, de, fr, es, pt-BR, ja,
zh-Hans, zh-Hant, ko, it, nl, pl, ru, uk, id, vi).

Testing: `rclone serve webdav <dir> --addr 127.0.0.1:<port> --user u
--pass p` serves a folder over WebDAV; integration tests run against it
the way the S3 tests run against MinIO or moto.
