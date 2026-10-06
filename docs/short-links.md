# Clean URLs and short links

The implementation spec for `{short}` (P0) and Bring Your Own Shortener
(P1) on every platform: Mac, Windows, iOS/Android, plus the local API, the
CLI, the MCP server and Raycast. The product decisions behind it are in the
private decision report (`resources/aktar/kisa-link-raporu.md`, frozen
2026-10-06). Provider definitions live in `short-link-providers.json` next
to this file; every app ships a copy of it.

Principle: **Aktar manages the workflow. You own the infrastructure.**
Aktar creates and formats links and, if asked, sends them to the user's own
shortener; the traffic never comes to Aktar. Copy says "Your links and click
data stay in your infrastructure", never "we never see anything". Client
logs mask URLs and never contain secrets.

## P0: `{short}` (clean URLs)

### Token

- `{short}` in a path template becomes a 7-character base62 code
  (`0-9A-Za-z`), e.g. `A7kdP2x`.
- Generated from the OS CSPRNG (Apple `SecRandomCopyBytes`, Rust
  `getrandom`/`OsRng`, mobile `expo-crypto` `getRandomBytes`), never
  `Math.random()` or similar. Unbiased: rejection sampling (draw a byte,
  discard values >= 248, use `value % 62`).
- `{short}` counts as a unique token, like `{uuid}` and `{random}` (no
  "numbered key" fallback for it).
- It is an identifier, not access control. Public bucket links stay public.
  The form's help text says so: "{short} makes links shorter, not private.
  For private sharing, keep the bucket private and copy temporary links."

### Collision rule (atomic where possible)

For a key that contains `{short}`:

1. Generate the key.
2. Create the object with a conditional write, `If-None-Match: *`, on
   providers that honor it: Amazon S3 and Cloudflare R2 (Windows already has
   `supports_conditional_writes` for these two presets). For multipart
   uploads the condition goes on `CompleteMultipartUpload`.
3. On `412 Precondition Failed` (or the provider's conditional-conflict
   error), generate a brand-new code (never append a number) and retry.
4. `MAX_SHORT_KEY_ATTEMPTS = 5`. If all five collide, the upload fails with
   a clear storage error; it never overwrites and never silently falls back
   to a uuid path.
5. Providers without conditional writes (B2, MinIO, DigitalOcean, other
   S3-compatible): check with `HEAD` first (exists → new code, same attempt
   limit), then a plain PUT. Practically safe at 62^7, not guaranteed.

Tests on every platform:
- Forced collision: the random source returns `ABC1234`, `ABC1234`,
  `XYZ9876`; with `ABC1234` already in the bucket (or the conditional PUT
  answering 412), the upload succeeds as `XYZ9876`.
- Five collisions → error, nothing overwritten.
- Generator: only base62 characters, length 7, roughly uniform over a large
  sample.

### Templates and presets

- **New destinations default to `{year}/{month}/{short}.{ext}`.** Existing
  destinations are never migrated.
- The path template field gets a presets menu:
  - **Clean URL (Recommended):** `{short}.{ext}`
  - **Short with date:** `{year}/{month}/{short}.{ext}`
  - **Original file name:** `{filename}.{ext}`
  - (keep any presets the platform already has)
- Set Up Cloudflare R2: when "My Domain" is chosen, the destination is saved
  with `{short}.{ext}`; with r2.dev it uses the new default.
- `{short}` is added to the list of template tokens wherever the form lists
  them, in all 17 languages.

### Custom-domain suggestion

- A destination "uses its own domain" when the host of its public base URL
  differs from the provider-generated hosts: the endpoint host, `*.r2.dev`,
  and the S3 bucket hosts (`*.amazonaws.com`, `*.backblazeb2.com`,
  `*.digitaloceanspaces.com`). Set Up Cloudflare R2 already knows (r2.dev vs
  My Domain).
- If it does and the template doesn't contain `{short}`, the destination
  form shows a small dismissible note:
  **Make your links cleaner.** Use `{short}` to create links like
  `files.example.com/A7kdP2x.png`. [Use Clean URL]
  The example uses the destination's real host. Dismissed per destination.
- Wording: never "URL shortener" for P0. "Clean links", "shorter paths".

### Compatibility

Identifier semantics (token, alphabet, length, collision rule) ship on all
platforms in the same release, because Share to Another Device carries the
template. The presets menu and the suggestion are UI and may roll out
separately if needed.

## P1: Bring Your Own Shortener

### Scope

Providers (all in P1, shipped together):
- Self-hosted: **Shlink**, **YOURLS**, **Kutt**
- Hosted: **Dub**, **Short.io**
- Escape hatches: **Custom HTTP** (with Test) and **ShareX `.sxcu` import**

### Destination settings

`DestinationConfig.shortLinks` (nil = off):

```
{
  "providerId": "shlink" | "yourls" | "kutt" | "dub" | "shortio" | "custom",
  "endpoint": "https://s.example.com",     // base URL for self-hosted and custom; ignored for dub/shortio
  "domain": "s.example.com",               // optional; required for shortio
  "custom": { ...CustomDefinition... },    // providerId == "custom" (manual or imported .sxcu)
  "onlyLongerThan": 0,                     // shorten only links longer than N characters; 0 = always
  "shortenTemporaryLinks": false
}
```

The secret (API key / signature / token) is stored with the destination's
keys in Keychain / Credential Manager / secure store as
`StorageCredentials.shortLinkToken`, never in the config or the definition.
It travels with Share to Another Device like `cloudflareToken`.

### Definitions

`short-link-providers.json` describes each built-in provider as HTTP
configuration, not code. The schema is deliberately narrow: no conditions,
scripting, regex, chained requests or computed headers.

```
{
  "id", "name", "kind": "selfHosted" | "hosted",
  "baseUrl": "https://api.dub.co" | null,          // null: use the destination's endpoint
  "needsDomain": bool,
  "auth": { "type": "header" | "bearer" | "query" | "basic", "name": "X-Api-Key" },
  "create":  Request + { "shortUrlPath", "idPath" },
  "delete":  Request | null,
  "update":  Request | null,                       // change destination URL
  "stats":   Request + { "clicksPath", "lastClickPath" | null } | null,
  "test":    Request,                              // authenticated, read-only
  "capabilities": {
    "delete": bool, "updateDestination": bool,
    "expiration": "absolute" | "relative" | false,
    "customCode": bool, "customDomain": bool,
    "stats": { "clicks": bool, "lastClick": bool }
  }
}
Request = { "method", "path", "query": {k: template}, "headers": {k: template},
            "body": JSON template | null, "bodyType": "json" | "form" | null,
            "errorPath": "path" | null,
            "successStatuses": [409] }                     // optional: non-2xx statuses that still succeed
```

Templates may use `{url}`, `{id}`, `{domain}`, `{expiresAt}` (ISO 8601),
`{expiresAtUnix}`, `{expiresInSeconds}`, `{expiresInMinutes}`, `{token}`.
Any query parameter or body value that contains a placeholder with no value
(e.g. no expiry, no domain) is omitted entirely, not sent empty: Shlink
treats `?domain=` as the domain "" (404 for links on the default domain),
and Kutt rejects `" minutes"`. Paths use dot notation with array
indexes (`data.tiny_url`, `visits.data.0.date`). Auth is generic only: a
header (optionally `Bearer `), a query parameter, or HTTP basic. YOURLS's
static `signature` is a query parameter; its time-limited signature is not
supported.

### Built-in providers

The exact requests are in `short-link-providers.json` (verified 2026-10-06
against Shlink 5.1.7, YOURLS 1.10.6 and Kutt 3.2.6 source and the live Dub
and Short.io APIs). Behavior worth knowing:

- **Shlink:** stats and last click come from one request, `GET
  /rest/v3/short-urls/{id}/visits?itemsPerPage=1` (`visits.pagination.totalItems`,
  `visits.data.0.date`, newest first). Delete fails with 422 once a link
  passes the server's visit threshold (15 by default); that's a cleanup
  failure (`orphaned`), not an error for the user's delete.
- **YOURLS:** `format=json` on every call (the default is XML). Create is a
  POST form; an existing URL returns 409 with the existing short link, which
  counts as success (`"successStatuses": [409]` on its create request). No delete, update, expiry or last click in core. A
  public install accepts any signature, so Test can't catch a wrong key.
- **Kutt:** `expire_in` is an `ms` string ("30 minutes"), at least 1 minute.
  Stats via `GET /api/v2/links/{id}/stats` (`visit_count`); no last click.
  PATCH needs only `target` but returns 400 when nothing changes (treat as
  success when the target is already right). `"reuse": false` must stay in
  the body: with a wrong key an instance that allows anonymous links would
  otherwise create an anonymous link instead of failing.
- **Dub:** stats via `GET /links/info?linkId={id}` (`clicks`, `lastClicked`).
  Expiry is Pro-only: on Free, create with an expiry fails with 403 and the
  provider's message is shown.
- **Short.io:** stats at `https://statistics.short.io/statistics/link/{id}?period=total`
  (`totalClicks`; the id format needs a live check). Error field differs by
  endpoint (`message` on create/update, `error` on delete). `expiresAt`
  accepts ISO or milliseconds; expiry is plan-dependent (402).

Anything marked "verify" is checked against the provider's current docs or
source before it ships; if a capability can't be verified it is set to false
rather than guessed.

### Custom HTTP and `.sxcu`

- Custom HTTP: a form for the create request (method, URL, headers, query,
  JSON or form body with `{url}`), the response path for the short URL and
  optionally the id, an optional delete request, and a Test button that
  shortens `https://getaktar.com/` and shows the result.
- `.sxcu` import: ShareX custom uploaders with `DestinationType` containing
  `URLShortener`. Map `RequestMethod`, `RequestURL`, `Parameters`, `Headers`,
  `Body` (`JSON`, `FormURLEncoded`, `None`), `Data`/`Arguments` (`{input}` →
  `{url}`), `URL` (`{json:path}` or legacy `$json:path$` → response path).
  Unsupported features (regex, `{response}` transforms, file form fields,
  chained calls) refuse the import with a clear message instead of guessing.
- **Import is a consent screen**, not a silent import:
  "This configuration will send your API token to **short.example.com**."
  plus method, full endpoint and which headers/parameters carry secrets.
  Values that look like secrets in headers/parameters/body are moved into
  `shortLinkToken` and the definition references `{token}`.
- `http://` endpoints are refused by default; allowing one needs an explicit
  "Allow insecure HTTP" choice with a warning.
- Secrets never appear in logs, history, notifications or error messages.

### Short link records

Separate records, one upload may have several:

```
ShortLink {
  id, uploadID, provider (definition id or "custom"), providerName,
  providerId (the provider's id/code, for delete/update/stats),
  shortUrl, targetUrl, createdAt, expiresAt?,
  status: active | expired | deleted | orphaned | unknown,
  clicks?, lastClickAt?, statsCheckedAt?
}
```

The UI shows one active short link per upload (the newest `active` one);
older ones are listed in the upload's details and can be deleted.

### Behavior rules (invariants)

1. **Short links never break uploads, deletes or moves.** The file
   operation completes on its own; the short link is auxiliary.
2. **Create:** after a successful upload, if the destination has
   `shortLinks`, the link isn't a temporary one (see 6), and its length is
   over `onlyLongerThan`: create the short link with the upload's expiry
   when the provider supports expiration (relative or absolute).
3. **Failure:** copy the original link and say so: notification "Short link
   couldn't be created. The original link was copied instead." with a
   **Retry** action. Never silent.
4. **Output:** the copied text uses the short link: URL, Markdown, HTML and
   the custom template's `{url}`. Custom templates also get `{shortUrl}`
   and `{longUrl}`. QR codes encode the short link when there is one,
   otherwise the long one.
5. **Delete:** delete the file first, then try to delete every short link of
   the upload. Failure: "File deleted ✓ / Short link cleanup failed ⚠", the
   record becomes `orphaned` ("Short link may still exist"). Providers
   without delete: mark `orphaned` and say the link may still exist.
6. **Temporary (presigned) links:** never shortened unless
   `shortenTemporaryLinks` is on, and that toggle is only available when the
   provider supports expiration. Then the short link expires with the
   temporary link: "Short link will expire together with the original
   temporary URL." A short link that outlives its target is never created.
7. **Move (bucket view rename/move):** a short link is stable only when the
   provider supports `updateDestination`. With it: create the new object,
   update the short link's target, delete the old object; if the update
   fails, keep the old object and mark the record `unknown`. Without it:
   warn before moving, "This short-link provider cannot update existing
   destinations. Moving this file may invalidate its short link."; if the
   user moves anyway, mark it `orphaned`. Never create a replacement short
   link silently.
8. **Replace File:** the key is the same, so the short link is untouched.
9. **Duplicate reuse:** when an upload reuses an existing upload's link, it
   also reuses that upload's active short link.
10. **Expiry:** an upload's auto-delete marks its short links `expired`
    locally (the provider expires them on its side when it supports it).
11. **Folder uploads** (keep-structure, many files): shortening applies to
    the single link Aktar copies (ZIP or folder link), not every file.

### Surfaces

- History / Library: active short link shown under the file; "Copy Short
  Link", "Copy Original Link", "Create Short Link" (when none, or after
  switching provider), "Delete Short Link"; status badge for
  orphaned/unknown/expired; clicks and last click when the provider has
  stats ("12 clicks · last clicked 2h ago"), fetched on demand (opening the
  details) and cached.
- Destination form: a "Short Links" section: Off / provider picker (Shlink,
  YOURLS, Kutt, Dub, Short.io, Custom HTTP…), endpoint, domain, API key,
  Test, "Import ShareX Configuration (.sxcu)…", "Only shorten links longer
  than", "Also shorten temporary links" (only with expiration support), and
  for hosted providers the note "This service sees every link you shorten
  and every click."
- Local API: upload DTO gets `shortUrl` (active, or null); `POST
  /v1/uploads/{id}/short-link` creates one (or returns the active one);
  `GET /v1/uploads/{id}/short-link` returns it with stats when available.
- CLI: `aktar upload --short` / `--no-short` (overrides the destination
  setting for this run), `shortUrl` in `--json`, `-f` formats use the short
  link; `aktar history --json` includes `shortUrl`.
- MCP: `upload_file`, `upload_clipboard`, `search_uploads` results include
  `shortUrl`.
- Raycast: show and copy the short link (separate PR).
- Webhooks: `shortUrl` in the payload (null when none).
- Share to Another Device: carries `shortLinks` and `shortLinkToken`.

All new strings in 17 languages.
