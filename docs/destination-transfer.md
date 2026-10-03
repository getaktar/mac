# Destination transfer (QR), format v1

"Share to Another Device" moves one storage destination (its settings and
access keys) from one Aktar app to another (Mac, Windows, iOS, Android) as a
QR code or a copied link. It's protected by a short transfer code that's
shown next to the QR code and typed on the receiving device. All apps produce
and accept exactly this format; the Mac implementation is
`Sources/Aktar/Transfer/DestinationTransfer.swift`, and
`Tests/AktarTests/DestinationTransferTests.swift` checks it against the test
vectors the other apps share.

## Transfer code

- 12 characters from the Crockford base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`
  (60 bits). Generate each char from a CSPRNG byte: `alphabet[byte & 31]` (unbiased).
- Displayed as `XXXX-XXXX-XXXX` in a monospaced font.
- Input normalization: uppercase; remove spaces and hyphens; map `O`->`0`, `I`->`1`,
  `L`->`1`. After that it must be exactly 12 chars, all in the alphabet, else invalid
  (do not try to decrypt).
- KDF input is the normalized 12 ASCII chars (no hyphen).

## Crypto

- Key: PBKDF2-HMAC-SHA256(password = normalized code, salt = 16 random bytes,
  iterations = 20000, length = 32 bytes).
- Cipher: AES-256-GCM, nonce = 12 random bytes, 16-byte tag,
  additional authenticated data = ASCII `aktar-transfer-v1`.
- A fresh code, salt and nonce for every "Share to Another Device" opening.

## Envelope and link

```
bytes  = [version: 1 byte = 0x01] [salt: 16] [nonce: 12] [ciphertext || tag]
link   = "aktar://import#" + base64url(bytes)   (RFC 4648 URL alphabet, no padding)
```

- The data is in the URL fragment so it never reaches a server and the iOS camera
  can still open the link in Aktar.
- The QR code contains the link (byte mode, error correction M, which is what every
  app already uses). The transfer code is NOT in the QR code and NOT in the link.
- Parsing input (scanned or pasted): trim whitespace; accept the full link
  (scheme/host case-insensitive) or just the base64url part. Anything that does not
  decode to at least 1 + 16 + 12 + 16 bytes is "not an Aktar transfer".
- Version byte > 1: "made by a newer version of Aktar". Version byte 0 or other
  garbage: "not an Aktar transfer".
- GCM authentication failure: "wrong code".

## Plaintext (UTF-8 JSON)

```json
{
  "v": 1,
  "destination": { ...DestinationConfig fields... },
  "credentials": { "accessKeyId": "...", "secretAccessKey": "...", "sessionToken": "..." },
  "customTemplate": "![{filename}]({url})"
}
```

- `destination` uses the same camelCase field names the apps already persist in
  destinations.json: `id` (uppercase UUID string), `name`, `preset`, `accountID`,
  `endpoint`, `region`, `bucket`, `publicBaseURL`, `objectPathTemplate`,
  `forcePathStyle`, `outputMode`, `expiryDays`, `temporaryLink`, `imageMetadata`,
  `folderUpload`, `imageProcessing` (`{format, quality, maxLongEdge}`).
  Optional fields are omitted when unset. `isDefault` is never sent.
- `sessionToken` is omitted when unset. `customTemplate` is only sent when
  `destination.outputMode == "custom"` (it is app-level today).
- `v` inside the JSON greater than 1: "newer version" error.

### Decoding rules (lenient, never crash, never lose other data)

- Unknown fields anywhere: ignore.
- Required: `destination.id` (valid UUID; normalize to uppercase), `name`, `preset`
  (one of the six known raw values), `endpoint`, `bucket`, `publicBaseURL`,
  `credentials.accessKeyId`, `credentials.secretAccessKey` (non-empty strings).
  Missing or invalid: "not an Aktar transfer".
- Defaults when missing: `region` -> preset default region; `objectPathTemplate` ->
  `{year}/{month}/{uuid}.{ext}`; `forcePathStyle` -> preset default; `accountID` -> unset.
- Optional enum/number fields with an invalid value (unknown raw value, wrong type,
  not in the allowed set, e.g. temporaryLink not in 300/900/3600/86400/604800) -> unset.
- `imageProcessing`: if `format` is invalid drop the whole object; invalid
  `quality`/`maxLongEdge` -> null within it (follow each app's existing sanitize rules).
- The `minimal` test vector exercises these rules.

## On the Mac

- Share: Settings > Destinations, a destination's menu > Share to Another
  Device. The keys are read from the Keychain; the window shows the QR code,
  the code and Copy Transfer Link (the link only), and closes itself after
  10 minutes. Every opening makes a new code, salt and nonce. The window is
  left out of screenshots, screen recordings and screen sharing.
- Import: Import from Another Device in Settings > Destinations (and its
  empty state), on the Welcome window, or an `aktar://import#...` link, which
  only fills the link in. Scan the QR code with the Mac's camera or paste the
  link, then type the code; the field formats it as `XXXX-XXXX-XXXX` while
  it's typed or pasted. If the destination is already there, choose Update
  Existing or Add as Copy (with a warning when the imported endpoint or
  bucket differs from the existing one's). There's no form to check: the
  destination is saved right away, keys in the Keychain, the first one
  becomes the default, and an imported `customTemplate` is only taken over
  while the Mac still has the default template. The same window then says it
  was added or updated, runs Test Connection by itself and shows the result,
  with Edit (the usual Edit Destination form) and Done. A failed test leaves
  the destination saved. Update Existing keeps auto-delete as it was while
  the endpoint, bucket and region stay the same; a new destination starts
  with auto-delete not set up.
