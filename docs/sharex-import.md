# Import from ShareX

Moving from ShareX should take one click: Aktar reads ShareX's own settings
and turns its S3 and Backblaze B2 uploaders, its SFTP accounts and its
ownCloud / Nextcloud uploader (as WebDAV) into Aktar destinations, its
URL-shortener custom uploaders into short link settings (short-links.md,
".sxcu"), and, on Windows, its upload history into Aktar's history.

| Part | Mac | Windows | iOS | Android |
|---|---|---|---|---|
| Destinations from UploadersConfig.json | yes (pick the file) | yes (found automatically, or pick it) | n/a | n/a |
| Secret keys | typed in (DPAPI can't be read off Windows) | read with DPAPI | n/a | n/a |
| History | no | yes | n/a | n/a |

Source of truth for ShareX's formats: the ShareX repo, `develop` branch
(checked 2026-11-09): `ShareX.UploadersLib/FileUploaders/AmazonS3Settings.cs`,
`AmazonS3.cs` (`GetUploadPath`, `GetObjectBaseURL`, `GetRegion`),
`UploadersConfig.cs` (B2 and ownCloud fields), `FileUploaders/FTPAccount.cs`,
`FileUploaders/SFTP.cs`, `FileUploaders/OwnCloud.cs` (checked 2026-11-27),
`ShareX.HelpersLib/Settings/DPAPIEncryptedStringValueProvider.cs`,
`ShareX.HistoryLib/Managers/HistoryManagerSQLite.cs`,
`ShareX/Infrastructure/AppPaths.cs`, `PersonalPathManager.cs`, `ShareX/SettingManager.cs`.

## Finding ShareX's files (Windows)

The personal folder, first match wins:

1. `PersonalPath.cfg` next to `ShareX.exe` (portable installs; the exe's
   folder is found through the uninstall registry key
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\ShareX_is1` or
   `HKLM\...` `InstallLocation`, or `%ProgramFiles%\ShareX`), or a `Portable`
   file there (then the folder is `<exe folder>\ShareX`).
2. Registry `HKCU\Software\ShareX` value `PersonalPath`, then
   `HKLM\SOFTWARE\ShareX` (SystemOptions.PersonalPath).
3. `%USERPROFILE%\Documents\ShareX\PersonalPath.cfg`, then
   `%LOCALAPPDATA%\ShareX\PersonalPath.cfg` (older location): its trimmed
   text is the folder (relative paths are relative to the exe's folder).
4. `%USERPROFILE%\Documents\ShareX` (the Documents known folder, which may
   be redirected: use `SHGetKnownFolderPath(FOLDERID_Documents)`).

The Microsoft Store build of ShareX uses the same Documents folder.

In that folder:

- Settings: `UploadersConfig.json`, or the machine-specific
  `UploadersConfig-<sanitized machine name>.json` when it exists (prefer it).
  ApplicationConfig.json can point uploaders elsewhere
  (`CustomUploadersConfigPath`): if set and that folder has the file, use it.
- History: `History.db` (SQLite, ShareX 18+), else `History.json` (older:
  a JSON array, possibly written without the outer brackets, so wrap it in
  `[` `]` if it doesn't start with one).
- Backups (`Backup\UploadersConfig-*.json`) are not read.

Read files shared (ShareX may be running): open read-only, and copy
History.db (with `-wal`/`-shm` if present) to a temp folder before opening it.

On the Mac (and as "Choose File..." on Windows), the user picks
`UploadersConfig.json` (or a `.sxb` ShareX backup, a ZIP that has it at its
root), max 5 MB.

## Destinations

### Amazon S3 uploader (`AmazonS3Settings`)

Imported when `AccessKeyID`, `Endpoint` and `Bucket` are set.

| ShareX | Aktar |
|---|---|
| `AccessKeyID` | Access Key ID |
| `SecretAccessKey` | Secret Access Key (see "Secrets") |
| `Endpoint` (`s3.amazonaws.com`, `s3.eu-west-1.amazonaws.com`, `https://<acct>.r2.cloudflarestorage.com`, ...; scheme optional, `https://` if missing) | endpoint |
| `Region` (empty: from the endpoint as `GetRegion` does: `s3.<region>.amazonaws.com` / `s3-<region>`; otherwise `us-east-1`) | region (`auto` for R2) |
| `UsePathStyle` | force path style |
| `Bucket` | bucket |
| `UseCustomCNAME` + `CustomDomain` | public base URL (CustomDomain may contain ShareX syntax like `$prompt$` or `{...}`; if it has `$` or `{`, leave the base URL empty and say so in the review) |
| neither | public base URL = `<endpoint>/<bucket>` (path style), as ShareX does |
| `ObjectPrefix` (default `ShareX/%y/%mo`) | path template, see below |
| `RemoveExtensionImage/Video/Text` | ignored (Aktar keeps extensions); mention in the review if any is on |
| `StorageClass`, `SetPublicACL`, `SignedPayload`, multipart settings | ignored |

Preset: Cloudflare R2 when the endpoint host ends with
`.r2.cloudflarestorage.com` (account ID from the first label); Backblaze B2
for `s3.<region>.backblazeb2.com`; DigitalOcean Spaces for
`*.digitaloceanspaces.com`; Amazon S3 for `*.amazonaws.com`; otherwise
Other S3-Compatible. Name: "ShareX: <bucket>".

### Backblaze B2 uploader (`B2ApplicationKeyId`, `B2ApplicationKey`, `B2BucketName`, `B2UploadPath`, `B2UseCustomUrl`, `B2CustomUrl`)

Imported when key ID and bucket name are set. B2's S3 API takes the same
key, but its endpoint has a region: call `b2_authorize_account`
(`GET https://api.backblazeb2.com/b2api/v3/b2_authorize_account`, Basic
auth keyId:key) and take `apiInfo.storageApi.s3ApiUrl`
(`https://s3.<region>.backblazeb2.com`); region = the `<region>` part. If
that call fails (or the key isn't available yet, Mac), leave the endpoint
empty and ask for it in the review. Public base URL: `B2CustomUrl` when
`B2UseCustomUrl`, else `https://f<NNN>.backblazeb2.com/file/<bucket>` from
`apiInfo.storageApi.downloadUrl`. Path template from `B2UploadPath` like
`ObjectPrefix`. Preset Backblaze B2, name "ShareX: <bucket> (B2)".

### SFTP accounts (`FTPAccountList`, `FTPAccount`)

Each account whose `Protocol` is `SFTP` (written as a name, since
ShareX's settings use a string enum converter; 2 in a numbered file)
becomes an SFTP destination. `FTP` and `FTPS` accounts are listed as not
imported ("Plain FTP and FTPS aren't supported. Use SFTP.").

| ShareX | Aktar |
|---|---|
| `Host`, `Port` (FTPAccount's default is 21, kept as it is) | Server: `host`, or `host:port` when the port isn't 22 (`[v6]:port` for an IPv6 address) |
| `Username` | User name |
| `Password` (`[JsonEncrypt]`) | Password, when `Keypath` is empty |
| `Keypath` (a file on the Windows PC) | Private key: the review asks for the key file on the Mac ("Choose Key File..."); the desktop app reads it when it's there |
| `Passphrase` (`[JsonEncrypt]`) | Key Passphrase |
| `SubFolderPath` (`%host` replaced; relative to the login folder unless it starts with `/`) | its fixed part (the folders before the first one with a `%` token) is the Folder; the rest is the path template, as for `ObjectPrefix` |
| `HttpHomePath` (`%host` replaced) + `BrowserProtocol` | Public Base URL: the home path with its own scheme when it has one, else `BrowserProtocol`'s; empty home path: the host without a leading `ftp.`, as ShareX does. With `HttpHomePathAutoAddSubFolderPath` (default on), the Folder's fixed part is added to it. ShareX syntax (`$`, `{`, `%`, `?`) leaves it empty for the review |
| `HttpHomePathAutoAddSubFolderPath` off | the link has no sub folder, so files go straight into the fixed part and the template is `{filename}.{ext}`; dated folders are mentioned as dropped |
| `HttpHomePathNoExtension` | ignored (Aktar keeps extensions); mentioned |
| `IsActive`, `FTPSEncryption`, `FTPSCertificateLocation` | ignored |

Name: "ShareX: <Name>", or the host when the name is ShareX's default
"New account". The host key isn't in ShareX's settings: it's trusted on
the first connection (the import's Test Connection).

### ownCloud / Nextcloud (`OwnCloudHost`, `OwnCloudUsername`, `OwnCloudPassword`, `OwnCloudPath`)

Imported as a WebDAV destination when the host and user name are set.
ShareX uploads to `<host>/remote.php/webdav/<path>` (OwnCloud.cs; `https://`
added to a host without a scheme, as `URLHelpers.FixPrefix` does), so that's
the Server URL. ShareX's links are share links it makes for each file
through the OCS API (`OwnCloudCreateShare`, `OwnCloudDirectLink`, expiry),
which Aktar doesn't make: the Public Base URL is left empty with a note,
and the review asks for the web address the folder is served from. An
`http://` host (other than this Mac) breaks the WebDAV https rule, and the
review says so. Name: "ShareX: <host> (Nextcloud)".

### Path template

ShareX's key is `<ObjectPrefix parsed>/<file name>`. Aktar's template is the
prefix converted plus `/{filename}.{ext}`:

| ShareX | Aktar |
|---|---|
| `%y` | `{year}` |
| `%mo` | `{month}` |
| `%d` | `{day}` |
| `%guid` | `{uuid}` |
| `%ra{N}`, `%ra`, `%rna{N}`, `%rx{N}`, `%rn` | `{random}` |
| literal text (letters, digits, `-_./`) | kept |
| anything else (`%h`, `%mi`, `%s`, `%pn`, `%t`, `%i`, `%un`, `%cn`, `%yy`, `%mon`, `%w`, `%unix`, ...) | not representable |

If anything isn't representable, the template becomes Aktar's default
(`{year}/{month}/{short}.{ext}`) and the review says which part was dropped.
An empty prefix gives `{filename}.{ext}`. Leading/trailing `/` are trimmed.

### Secrets

ShareX stores `SecretAccessKey` and `B2ApplicationKey` (and other
`[JsonEncrypt]` fields) as `$DPAPIEncrypted$` + base64 of
`CryptProtectData` output (current user scope, no entropy). Older files have
them in plain text.

- Windows: `CryptUnprotectData` on the base64-decoded bytes. Failure (another
  user's file, another PC): treat as missing.
- Mac: can't decrypt. The review asks for the secret key for each such
  destination ("ShareX encrypted this key for Windows. Paste it from your
  provider, or import on the Windows PC and use Share to Another Device.").

Secrets go straight to the Keychain / Credential Manager, never into
destinations.json or logs.

### Custom uploaders

`CustomUploadersList` holds ShareX custom uploaders (the same JSON as
`.sxcu` files). Those whose `DestinationType` includes `URLShortener` are
offered for import through the existing .sxcu shortener import (one review
per shortener, attached to the destination the user picks). File uploaders
to arbitrary HTTP endpoints aren't supported and are listed as skipped, with
their names.

### Review

One sheet listing what was found: each destination (name, provider, bucket,
or server and folder, public URL, template, with a checkbox, on by
default), each shortener, the history count (Windows), and the skipped
items with a reason (FTP and FTPS accounts, Imgur,
Google Drive, custom file uploaders, unrepresentable templates). Importing
runs Test Connection for each new destination right away (as the QR import
does) and marks failures. Nothing is imported twice: a destination with the
same endpoint + bucket + access key already in Aktar is skipped ("already in
Aktar"). The first imported destination becomes the default only if there
was none.

Same rules as the QR import's review (destination-transfer.md): hooks, Use
For and other automation don't exist in ShareX, so nothing runs that the
user didn't set.

## History (Windows)

ShareX's `History` table: `Id, FileName, FilePath, DateTime (ISO 8601 "o"),
Type, Host, URL, ThumbnailURL, DeletionURL, ShortenedURL, Tags`.

Only entries whose `URL` lies under an imported destination's public base
URL become history records (ShareX's own `TryGetObjectKey`: same scheme,
host, port, and the path starts with the base path + `/`; the rest,
percent-decoded, is the object key). Each record: local filename =
`FileName`, key as above, public URL = `URL`, destination = that
destination, created = `DateTime`, size 0 and MIME type from the extension
(not known; HEAD is not done for thousands of entries), source label
"ShareX". A non-empty `ShortenedURL` is not imported (Aktar's short links
belong to a configured shortener). Duplicates (same destination + key) are
skipped, so importing twice is harmless. Other entries (Imgur, other hosts)
are counted as skipped.

## Where

- Mac: Settings > Destinations, "Import from ShareX..." under the existing
  add/import buttons (file picker).
- Windows: Settings > Destinations, "Import from ShareX" (shows "ShareX
  settings found in <folder>" when they are, else a file picker), and once,
  on first run with no destinations, a banner in the panel when ShareX's
  folder exists ("Import your ShareX uploaders?").
- Site: a "Switch from ShareX" guide page (site repo).

## Decisions made while building the Mac app

- The button is "Import from ShareX..." (Settings > Destinations, below
  Import from Another Device, and in the empty state).
- Region: as `GetRegion` for Amazon S3, `auto` for R2, and the region in
  the host for B2 (`s3.<region>.backblazeb2.com`) and Spaces
  (`<region>.digitaloceanspaces.com`), whose signatures need it.
- Path template tokens: `%mon`, `%mon2`, `%yy`, `%unix` and the others are
  matched longest first, so `%mon` isn't read as `%mo` + `n`. `%ra{N}` and
  the like take their `{...}` along. A `%` followed by letters Aktar doesn't
  know, and any character other than letters, digits and `-_./`, is
  unrepresentable.
- B2 on the Mac: `b2_authorize_account` is called when Import is pressed,
  with the key typed in the review; if it fails, the row says so and the
  endpoint can be typed instead. Nothing is saved until every selected row
  is complete.
- Shorteners: listed in the review; after importing, each has "Add to..."
  (any destination), which opens the existing .sxcu consent screen. A
  custom uploader that the .sxcu import refuses (http://, regex, ...) is
  listed as skipped with that reason.
- "Already in Aktar": same bucket and access key, and the same endpoint
  (for B2, whose endpoint isn't known yet, the bucket and key decide).
- Skipped uploaders listed: FTP and FTPS accounts (each as "FTP account
  <name>"), Imgur, Google Drive, Dropbox,
  OneDrive, Box, Google Cloud Storage, Azure Storage, Flickr, Photobucket
  (when their settings are filled in), custom file uploaders.
- `.sxb`: a ZIP read in place; `UploadersConfig.json` at its root, stored or
  deflated; at most 5 MB.
- SFTP with a key file (Mac): the review shows ShareX's key path and has
  "Choose Key File..." and Key Passphrase (unless the file has the
  passphrase in plain text); the key is checked (type, passphrase) before
  anything is saved. A password or passphrase ShareX encrypted for Windows
  is typed in, as for S3 keys.
