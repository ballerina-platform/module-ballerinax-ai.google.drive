# Change Log

This file documents all significant changes made to the Ballerina ai.google.drive package across releases.

## [Unreleased]

### Changed

- **Breaking:** `Source.folder` and `Source.files` are replaced by a single `Source.resourceIds` list
  holding files and/or folders in any combination. Drive addresses both by the same kind of
  opaque ID, so an entry's Drive MIME type — not the field it was written in — now decides
  whether it is fetched as one file or expanded as a folder. `recursive` is unchanged and still
  shapes folder expansion only; use one `Source` per traversal setting. A source that names a
  folder where a file was intended now loads that folder rather than reporting the mismatch,
  since the merged field no longer records which kind was expected.
- **Breaking:** `Source.includeExtensions` is removed. Folder listings no longer filter by file
  extension; every supported file in a listing is loaded. Filter the returned documents by their
  `fileName` metadata instead, or name the wanted files directly in `resourceIds`.

## [1.0.0] - 2026-07-30

### Added

- Initial release: `ai.google.drive:TextDataLoader`, an `ai:DataLoader` implementation that loads
  Google Drive files as `ai:TextDocument`s.
- Google Workspace natives (Docs, Sheets, Slides) exported to text; uploaded PDF and Microsoft
  Office documents (`docx`/`xlsx`/`pptx`, `doc`/`xls`/`ppt`) text-extracted with Apache Tika;
  ordinary text files downloaded and decoded.
- ID- and share-URL-based `Source` model, with optional recursion into sub-folders and an
  extension allowlist for folder listings.
- Charset-aware text decoding: byte-order mark, then the charset Drive declares, then UTF-8. Any
  BOM is stripped rather than carried into the document body.
- HTML markup rendered to plain text rather than stored as raw markup.
- Partial-failure handling: a file that cannot be loaded inside a folder listing is skipped with a
  warning and the walk continues; a file named explicitly is an error.
- Text-less PDF detection (scanned/image-only or blank), reported through a structured error
  reason rather than a message match.
- Configuration via the `ballerinax/googleapis.drive` connector's own `drive:ConnectionConfig`,
  with retry (exponential backoff over Drive's throttling and transient status codes) and a
  bounded response body applied by default when the caller sets neither.
- Connection reuse: the loader accepts either a `drive:ConnectionConfig` it builds a client from,
  or an existing `drive:Client` it borrows without owning.
- Document metadata: `fileName`, `mimeType`, `fileSize`, `createdAt`, `modifiedAt`, plus the Drive
  `fileId` and a `webUrl` citation link.

### Known limitations

- Google Sheets are exported as `text/csv`, which Google documents as first-sheet-only, so
  multi-tab spreadsheets lose every tab after the first.
- Drive shortcuts are not followed.
- GraalVM native image is not supported (`graalvmCompatible = false`) — the native-image metadata
  for the Apache POI / XMLBeans / Tika stack has not yet been generated and verified.
- No OCR: text-less PDFs are detected and reported, not read.

### Inherited from the `googleapis.drive` connector

- No service-account (JWT bearer) authentication; the connector's `auth` admits only a bearer
  token or an OAuth2 refresh-token grant.
- A file's size is unknown until it has been downloaded: the connector types `File.size` as `int`
  where Drive sends a JSON string, so the field cannot be requested. Memory is bounded by
  `responseLimits.maxEntityBodySize` rather than by a per-file ceiling.
- One extra `files.get` per loaded file: the connector's listing accepts no field mask, so the
  metadata timestamps cannot come from the listing itself.
- Drive's `incompleteSearch` flag is dropped by the connector's listing stream, so a partial
  listing cannot be distinguished from a complete one.
- Files Drive has flagged as abusive cannot be downloaded; there is no `acknowledgeAbuse` override.
- The connector rebuilds Drive failures as `error(<response body>)`, discarding the HTTP status
  code and the original cause, so a missing file is recognised by matching Drive's `notFound`
  reason text.
- The connector hardcodes the API root, so the loader cannot be pointed at a mock service. The
  traversal and content-routing paths in `drive_data_loader.bal` are therefore not covered by
  automated tests (~20% line coverage); the surrounding logic is.
