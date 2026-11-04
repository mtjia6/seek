# Security

Seek reads the contents of files on your Mac, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Instead, use GitHub's [private vulnerability reporting](https://github.com/mtjia6/seek/security/advisories/new). Include steps to reproduce and the macOS version. You'll get a reply within a week.

## Scope

In scope, for example:

- Seek reading or indexing files it shouldn't (hidden folders, excluded paths, other users' files).
- A crafted file (PDF, Office document, image) that crashes the extractor or makes it execute code.
- The index in `~/Library/Application Support/Seek/` being readable by other users.
- Any network access after the model download in `build.sh`.

Only the latest commit on `main` is supported.
