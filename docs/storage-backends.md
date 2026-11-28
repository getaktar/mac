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
   for users. Shipped in Mac 0.23.0 and desktop 0.17.0.
2. WebDAV, with QR transfer format 2, local API `kind` and the site.
   Shipped in Mac 0.23.0 and desktop 0.17.0.
3. SFTP (Mac 0.24.0, desktop 0.18.0).
4. The rest, in the same releases: mobile (WebDAV and SFTP), CLI and
   Raycast, ShareX import of WebDAV and SFTP destinations, previews in
   folders without public links. See "Phase 4" below.

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
for SFTP, the private key; see "SFTP"). Short link and Cloudflare tokens
stay where they are.

On Windows, Credential Manager caps a secret at 2560 bytes, which a
private key with the other tokens can pass: the desktop app splits
credential JSON over 2400 bytes into entries `<id>#1` ... `<id>#N` and
keeps `{"aktarChunks":N}` in the main entry. The Mac Keychain has no such
limit and keeps one item.

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

## SFTP (phase 3)

Preset `sftp`, display name "SFTP". It works with any SSH server that
offers the SFTP subsystem (OpenSSH, Hetzner Storage Box, Synology, a VPS),
with a web server serving the same folder for links.

Fields in the form: **Server** (`endpoint`: `host`, `host:port`, or
`[v6address]:port`; port 22 when left out), **Folder** (`bucket`: the
base folder on the server, absolute like `/var/www/files` or relative to
the login folder like `files`; empty is the login folder itself), **User
name** (`accessKeyId`), then a
choice of **Password** or **Private Key** (`secretAccessKey`), **Key
Passphrase** (optional, only for an encrypted key), **Public Base URL**
(required: SFTP itself has no links) and the path template as for S3.
Region, access keys and path style are hidden.

Credentials: `secretAccessKey` holds either the password or the private
key. A value starting with `-----BEGIN` is a key: OpenSSH
(`-----BEGIN OPENSSH PRIVATE KEY-----`), ed25519 or RSA; ECDSA where the
platform's library supports it. The passphrase goes in a new optional
`StorageCredentials` field `keyPassphrase`. The form offers "Choose Key
File..." that reads the file into the field; the file itself isn't kept.

On the Mac and the desktop (the SFTP core, see below): ed25519, RSA and
ECDSA keys in OpenSSH format, encrypted (bcrypt, as `ssh-keygen` writes
them) or not, and old PEM keys (`-----BEGIN RSA PRIVATE KEY-----`,
encrypted or not). DSA, security keys (`sk-...`) and PuTTY keys are
refused with their name. RSA signs in with the SHA-2 signature the server
says it takes (`server-sig-algs`), else `rsa-sha2-256`: OpenSSH 8.8 and
later refuse `ssh-rsa` (SHA-1). The form shows what kind of key was
chosen ("ed25519 key, encrypted"), not the key.

**Host key** (trust on first use, like `ssh`): the destination stores the
server's public key in a new optional field `sshHostKey`, in OpenSSH
format (`ssh-ed25519 AAAA...`). Test Connection shows its SHA-256
fingerprint (`SHA256:...`, as `ssh-keygen -l` prints it) and saving the
form stores it. A connection with no stored key accepts and stores the
key it sees. A connection whose key differs from the stored one is
refused before authenticating, with "The server's identity has changed
(SHA256:...). If you expected this, run Test Connection again and save."
Test Connection doesn't sign in to such a server either, so the password
never goes to a server that may be fake: it shows the saved and the new
fingerprint and takes the new key into the form. A second Test Connection
then signs in with the new key accepted, and saving stores it. The key
travels in QR transfers and in destinations.json; it isn't a secret.

The key seen on a first connection is written back to the destination
only while its endpoint is still the one connected to (it may have been
edited meanwhile). A stored `sshHostKey` that can't be read is refused
("The saved server key can't be read. Run Test Connection again and
save."), never taken as "any key"; the form's Test Connection then trusts
the key it sees, as for a destination without one.

Operations (paths are `<Folder>/<key>`, `/`-separated, never `..`):

| operation | SFTP |
|---|---|
| upload | `mkdir` each missing parent (an existing one is fine), write to `<dir>/.<name>.aktar-part` streamed, then rename over the target (`posix-rename@openssh.com` when offered, else remove the target and `rename`); the part file is removed on failure or cancel |
| put (pages, thumbnails) | same, from memory |
| get / download | `open` + `read` |
| delete | `remove` (no such file counts as done); a folder key (ending in `/`) is removed with `rmdir` only when it's empty |
| exists / info | `stat` (size, mtime) |
| list | `opendir` + `readdir` of the folder, one page, `.`, `..` and `.*.aktar-part` left out; directories are folders |
| listRecursively | `list` on each subfolder in turn |
| copy | read and write through the app (SFTP has no server-side copy), streamed, same part-file rule |
| move (local API, bucket browser) | `rename` on the server (capability `rename`), but copy + delete when short links must be updated to the new link, so the original stays if that fails |
| createFolder | `mkdir` with parents |
| publicURL | `publicBaseURL` + key, exactly as for S3 |

One SSH connection per destination is reused while operations follow each
other and closed after 60 s idle. Connect timeout 15 s. Keepalive while a
transfer runs.

Mac and desktop: one connection per server, port, user and secret,
shared by every operation (SFTP matches answers to requests by ID, so
they can run at once). Writes are sent in file order: some servers
(rclone without a VFS cache) refuse writes that arrive out of order
("Illegal seek"). Keepalives every 15 s; three unanswered ones end the
connection. Each SFTP request may wait 60 s for its answer.

**Test Connection** for SFTP: connect (shows the fingerprint), authenticate,
`stat` the folder, then the same test upload, public link check and delete
as for S3, with the same result lines.

Errors (the Mac and desktop share the English wording: "Could not sign
in. Check your user name, password or key.", "Folder not found on the
server (<path>). Check the Folder.", "<host> refused the connection.
Check the server and port.", "<host> didn't answer in time.", "<host>
couldn't be found. Check the server name."): authentication failed is "wrong user name, password or key"; an
encrypted key without a passphrase or with a wrong one is "the key's
passphrase is missing or wrong"; permission denied is "not allowed to
write here"; a missing folder is "folder not found"; connection refused,
timed out and DNS failures say so with the host; an unsupported key type
names it. Network errors and dropped connections are retried with the S3
backoff; authentication and permission errors are not.

Capabilities for SFTP: as for WebDAV (no temporary links, Delete after,
Request Files, multipart or conditional writes). QR transfer format 2,
local API `kind: "sftp"`, as for WebDAV.

Libraries: `russh` + `russh-sftp` (ring crypto, pure-Rust RSA) in the
SFTP core shared by the Mac and the desktop, sshj on Android.

**SFTP core.** The SSH and SFTP work (paths, keys, host keys, the
connection pool, the operations, part files, retries and the error kinds)
is one Rust crate, `aktar-sftp-core`. Its source of truth is the desktop
repo (getaktar/desktop, `crates/sftp-core`, with its unit tests and live
tests against rclone and OpenSSH); the desktop's `storage/sftp.rs` is a
thin adapter over it (its types, wording and credentials). The Mac repo
keeps an exact copy in `rust/sftp-core`, so it builds on its own:
`scripts/sync-sftp-core.sh` copies it from `../windows` (or `../desktop`,
or `DESKTOP_REPO`), and `--check` fails when the copies differ
(`release.sh` runs it). Change the core in the desktop repo, never in the
copy.

On the Mac, `rust/aktar-sftp-ffi` wraps the core with UniFFI (proc
macros): a client object with async methods (Swift `async`, run on the
library's own Tokio runtime, where the pool and its timers live),
callbacks for upload progress and a host key learned on first use, a
cancel token, the pure helpers as functions, and the core's errors as
`SftpError`, which `SFTPBackend.appError` words as the app's own errors.
`rust/uniffi-bindgen` is UniFFI's generator at the same version.
`scripts/build-sftp-core.sh` builds the static library (release profile:
LTO, `opt-level = "s"`) for the archs Xcode builds (`$ARCHS`; both for a
Release archive), lipos them and generates the Swift bindings into
`build/sftp-core` (gitignored): `lib/libaktar_sftp_ffi.a`,
`include/AktarSFTPFFI.h` + `module.modulemap`, `swift/AktarSFTP.swift`.
It skips the build when the Rust sources, the archs and the script are
unchanged. `project.yml` runs it from the aggregate target `SFTPCore`,
which the app and the tests depend on; both compile `AktarSFTP.swift` and
link the library. Building needs rustup and
`rustup target add aarch64-apple-darwin x86_64-apple-darwin` (CI does
the same). The same FFI crate builds for iOS (`--xcframework --ios`:
aarch64-apple-ios, and aarch64-apple-ios-sim + x86_64-apple-ios for the
Simulator, iOS 16.4 by default) into `build/sftp-core/AktarSFTP.xcframework`. Testing: `rclone serve sftp <dir>
--addr 127.0.0.1:<port> --user u --pass p` (and `--authorized-keys` for a
key), integration tests against it like the WebDAV ones.

## Phase 4

Ships with phase 3 (Mac 0.24.0, desktop 0.18.0, mobile 1.13.0, CLI and
Raycast updates).

- **Mobile** (iOS and Android): WebDAV in TypeScript (`fetch`, the same
  requests as above) and SFTP through a local Expo module (`modules/`,
  the SFTP core through aktar-sftp-ffi on iOS, sshj on Android). QR transfer accepts format 2. The add
  form gains WebDAV and SFTP; capabilities hide the same controls.
- **CLI and Raycast**: show the destination's `kind`, pass it on in JSON
  output, and turn a 409 "this destination can't do that" from the local
  API into a plain message instead of an error trace. Temporary link and
  Delete after options are hidden or refused for kinds without them.
- **ShareX import**: besides S3, B2 and shorteners, an SFTP account
  (`FTPAccountList` with protocol SFTP: host, port, user name, password
  or key file and passphrase, sub folder, HTTP home path for the public
  URL) becomes an SFTP destination, and ShareX's WebDAV-based uploaders
  (ownCloud/Nextcloud: host, user name, password, path) become WebDAV
  destinations. Plain FTP and FTPS accounts stay out of scope and are
  listed as skipped.
- **Previews without public links**: when a WebDAV or SFTP destination's
  public link doesn't load (or there's no Public Base URL that works),
  the bucket browser and history load previews and thumbnails through
  the backend (`get` with the size cap) instead of the public URL.
  Mac: thumbnails already came through the backend; previews open the
  link once per run (HEAD, then GET) and, when it doesn't load, download
  the file through the destination into Caches/Aktar/Previews (25 MB for
  images, PDFs and text, 200 MB for video and audio; copies older than a
  day are deleted, and Settings > General > Clear removes them).
- **Local API** (Mac and desktop): `expires` on a kind without lifecycle
  rules answers 409 "This destination can't delete uploads after a while
  (its storage has no lifecycle rules)."; a temporary link answers 409
  "This destination can't make temporary links."
