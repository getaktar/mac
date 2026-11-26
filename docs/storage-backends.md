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
