# Set Up Cloudflare R2

A destination for Cloudflare R2 without copying keys, an account ID or a
bucket name by hand. The user creates one API token from a link that fills
in its permissions, pastes it, and Aktar does the rest. Mac 0.16.0 first;
Windows and mobile follow the same steps and API calls.

## Why a token and not OAuth

Cloudflare opened OAuth to third-party apps in June 2026, but its scopes
have no way to create API tokens, and R2's S3 keys can only come from an
API token (temporary credentials need a parent token too). OAuth alone
would mean uploading through a Worker instead of S3 (Becket does this),
which would lose presigned links, multipart uploads and the rest of the S3
code on every platform. One pasted token keeps all of it.

## Flow

1. **Token.** "Open Cloudflare" opens the user token template:

   ```
   https://dash.cloudflare.com/profile/api-tokens
     ?permissionGroupKeys=[{"key":"workers_r2","type":"edit"},{"key":"zone","type":"read"}]
     &accountId=*&zoneId=all&name=Aktar
   ```

   (query values URL-encoded). R2 edit creates the bucket and is what the
   S3 keys can do; zone read lists domains for public links. The user
   selects Continue to summary, Create Token, copies it and pastes it.
2. **Check.** `GET /user/tokens/verify` gives the token's `id` (and
   `status`, which must be `active`). `GET /accounts` lists the accounts it
   can see; none means it was created for no account.
3. **Options.**
   - Account, when there's more than one.
   - Bucket: a new one (default `aktar`, then `aktar-2`...; 3 to 63
     lowercase letters, digits and hyphens, starting and ending with a
     letter or digit) or an existing one from
     `GET /accounts/{id}/r2/buckets` (`result.buckets[].name`).
   - Public links: the r2.dev address, or a domain from
     `GET /zones?account.id={id}&status=active` with a subdomain
     (default `files`, giving `files.example.com`).
   - Destination name, default "Cloudflare R2".
4. **Set up.**
   - New bucket: `POST /accounts/{id}/r2/buckets` `{"name"}`.
   - r2.dev: `PUT .../r2/buckets/{bucket}/domains/managed` `{"enabled": true}`;
     the base URL is `https://` + `result.domain`.
   - Domain: skip if `GET .../domains/custom` already lists it, else
     `POST .../domains/custom` `{"domain", "zoneId", "enabled": true, "minTLS": "1.2"}`.
     Cloudflare adds the DNS record and certificate; it takes a few
     minutes, so a failed public link check right after is expected and
     the result says so.
5. **Save.** A normal R2 destination: endpoint
   `https://{account}.r2.cloudflarestorage.com`, region `auto`, path
   template `{year}/{month}/{uuid}.{ext}`, auto-delete rules not yet
   checked. S3 keys: access key ID = token `id`, secret = lowercase hex
   SHA-256 of the token value. Only these go to the Keychain / Credential
   Manager / secure store; the token itself is not kept.
6. **Test.** Test Connection runs by itself after about two seconds (a new
   token can take a moment to reach R2), then Edit or Done, like Import
   from Another Device.

All calls go to `https://api.cloudflare.com/client/v4/` with
`Authorization: Bearer <token>`; errors are `{"success": false, "errors":
[{"message"}]}` and their messages are shown as they are.

## Where it is

Settings > Destinations: "Set Up Cloudflare R2..." next to Add Destination,
and the main button when there's no destination yet (with "Free up to
10 GB, set up in a minute"; R2's free tier is 10 GB-month of storage).
