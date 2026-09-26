# Security Policy

Aktar stores your storage-provider credentials (access key / secret key) in
the macOS Keychain only. They are never written to UserDefaults, plist files,
JSON config, or the local upload history database, and are never sent
anywhere except directly to the S3-compatible endpoint you configure.

## Reporting a Vulnerability

If you believe you've found a security issue in Aktar, please report it
privately rather than opening a public issue:

- Email **security@getaktar.com** with a description of the issue and steps
  to reproduce it.
- Please give us a reasonable amount of time to investigate and release a
  fix before any public disclosure.
- Only test against your own accounts/data. Do not attempt denial of
  service, data destruction, or social engineering against maintainers.

We'll acknowledge your report and keep you updated as we work on a fix.

## Supported Versions

Only the latest released version of Aktar is supported with security fixes.
