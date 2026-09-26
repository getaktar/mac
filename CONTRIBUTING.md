# Contributing

Please read our [Code of Conduct](CODE_OF_CONDUCT.md) before participating.

## Setup

```bash
brew install xcodegen gitleaks pre-commit
xcodegen generate
pre-commit install
```

`Aktar.xcodeproj` is generated from `project.yml` and is gitignored. Run
`xcodegen generate` again any time you add, move, or remove a source file,
or after pulling changes that touch `project.yml`.

`pre-commit install` activates the gitleaks hook, which scans staged changes
for hardcoded secrets before each commit.

## Pull requests

- Keep PRs focused on one change.
- Never commit real credentials, certificates, or provisioning profiles,
  even in tests or fixtures - use obviously-fake placeholder values.
- Make sure `xcodebuild build -project Aktar.xcodeproj -scheme Aktar` succeeds
  before opening a PR.
- Add a line under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for any
  user-facing change.

## Releasing (maintainers)

`scripts/release.sh` builds, signs with a Developer ID certificate, notarizes,
and packages a distributable DMG in `dist/`. One-time setup on the release
machine:

```bash
security find-identity -v -p codesigning   # confirm a "Developer ID Application" cert exists
xcrun notarytool store-credentials aktar-notarization \
  --key <path-to-AuthKey.p8> --key-id <key-id> --issuer <issuer-id>
```

Then just run:

```bash
./scripts/release.sh
```

The signing certificate and notarization credentials only ever live in the
local Keychain - never commit them, and never add them as CI secrets without
re-reading the tradeoffs first.
