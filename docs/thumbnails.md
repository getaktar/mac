# Thumbnails

Shared by the Mac, Windows, iOS and Android apps, so a bucket used from
several devices ends up with one set of thumbnails that every app can read,
and every app keeps it tidy.

## Setting (per destination)

`destination.thumbnails`, persisted with the other destination fields and sent
in a destination transfer (see destination-transfer.md):

| Value | Meaning |
|---|---|
| `off` | Nothing is made, downloaded or shown. History and the bucket view show file icons. No thumbnail requests are sent (see "Other destinations on the bucket" for the one exception). |
| `local` (default, also when unset) | Made on the device, kept only there. |
| `bucket` | Kept on the device too, and also saved to the bucket under `thumbnailPrefix`. |

`destination.thumbnailPrefix`: the bucket folder for `bucket` mode. Unset means
`.aktar/thumbnails/`. Normalized as: trim whitespace, drop leading `/`, drop
trailing `/`, then add one trailing `/`. Invalid (empty after normalizing, a
control character, a `.`, `..` or empty path segment, or starting with `tmp/`):
the form refuses it, and an import leaves it unset. The value is kept while the
mode isn't `bucket`, so switching back finds the same folder.

## Making one

- From the exact bytes that were uploaded (after conversion and metadata
  removal), while the upload runs, and waited for before the job finishes (a
  watched folder may move or delete the file right after). Never from a folder
  ZIP.
- Longest side 512 px, aspect ratio kept, EXIF orientation applied. Shown at
  no more than half their pixel size (256 pt), so they stay sharp on 2x
  displays. Thumbnails made at another size (older versions made 320 px) are
  used as they are; anything over 1024 px at a thumbnail's key is ignored.
- Use the OS thumbnailer so videos, PDFs, RAW photos and documents work: Quick
  Look (`QLThumbnailGenerator`, `.thumbnail` representation only, never the
  icon) on Mac and iOS, `IShellItemImageFactory::GetImage` with
  `SIIGBF_THUMBNAILONLY` on Windows, `ThumbnailUtils` / `MediaMetadataRetriever`
  / `PdfRenderer` on Android. Give up after 15 seconds.
- No thumbnail for archives, disk images, executables, apps, folders, or files
  without an extension.
- On the device: the same WebP per history entry (`<record id>.webp`; older
  versions wrote `.png`, still read), next to the history (not in a cache
  folder the OS may empty). Around 5-10 KB each; a PNG would be ten times that. A failed attempt is
  remembered so it isn't retried.

## In the bucket

Format: WebP (lossy, quality 80, alpha kept), `Content-Type: image/webp`,
the same bytes the device keeps.

Key: the file's key under the prefix, plus `.webp`. An expiring file's
thumbnail stays inside the same `tmp/{N}d/` folder, so the bucket's lifecycle
rule deletes both even when no app is running:

```
photos/cat.png          -> .aktar/thumbnails/photos/cat.png.webp
tmp/7d/photos/cat.png   -> tmp/7d/.aktar/thumbnails/photos/cat.png.webp
```

`tmp/{N}d/` means exactly the expiry folders Aktar uses (1, 7, 14, 30). A key
that is already inside a thumbnail folder (at the root or in a `tmp/{N}d/`
folder) has no thumbnail.

A thumbnail is current when its `Last-Modified` is not older than its file's.
An older one belongs to a file that was replaced since; ignore it and make a
new one.

## Keeping them in step with their files

"Thumbnail folders of a bucket" = the prefix of every destination on this
device that points at the same endpoint and bucket and has `bucket` mode.

- Upload: in `bucket` mode, PUT the thumbnail after the file. Then delete the
  thumbnail key in every other thumbnail folder of the bucket (and in its own,
  if none could be made): any thumbnail there belonged to a file that was at
  that key before.
- Delete (history, bucket view, watched folder, local API, expiry sweep):
  delete the thumbnail key in every thumbnail folder first, then the file. If
  deleting a thumbnail fails, don't delete the file, so a thumbnail never
  outlives its file. Deleting a key that doesn't exist succeeds.
- Rename or move: copy the file, copy each thumbnail that exists to the new
  key, delete the old thumbnails, delete the old file. Refuse a target inside a
  thumbnail folder.
- Expiry: the lifecycle rule deletes both. The app's own sweep deletes the
  thumbnail along with the file.
- Mode change in the destination form: leaving `bucket`, changing the prefix,
  or pointing the destination at another bucket asks whether to delete the
  thumbnails in the old folder (only `.webp` objects in it, at the root and in
  each `tmp/{N}d/` folder), unless another destination on that bucket still
  uses the folder. Turning thumbnails `off` deletes the ones on the device.

### Other destinations on the bucket

Several destinations (profiles) can share a bucket. Even a destination with
`off` or `local` mode deletes, moves and replaces thumbnails in the other
profiles' folders as above, so a deleted file never leaves its thumbnail
behind. Without any `bucket`-mode destination on that bucket, nothing extra is
sent.

## Showing them

- History row: the device's thumbnail. If it has none and the mode isn't `off`, once
  the row is shown: the bucket's thumbnail (`bucket` mode, written no earlier
  than 2 minutes before the upload), else download the file (at most 25 MB, and
  only if it is still that upload) and make one (saving it to the bucket in
  `bucket` mode). Not for deleted, expired or replaced uploads.
- Bucket view row: the history entry's thumbnail if that file is still the upload
  this device made; else the bucket's thumbnail if current; else make one from
  the file (25 MB limit) and, in `bucket` mode, save it to the bucket. Cache
  by key, size and last-modified date, and forget a key when its file is
  deleted or moved.
- Thumbnail folders are hidden from the bucket view, its search and the local
  API listing, and so is a dot folder (such as `.aktar/`) that leads to one.
