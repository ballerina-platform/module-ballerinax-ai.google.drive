# Ballerina Google Drive Data Loader

The `ballerinax/ai.google.drive` package provides a [`ai:DataLoader`](https://central.ballerina.io/ballerina/ai/latest) implementation that loads files from [Google Drive](https://www.google.com/drive/) and returns them as `ai:TextDocument`s — ready to chunk, embed, and index in a Ballerina AI / RAG pipeline.

It builds on the [`ballerinax/googleapis.drive`](https://central.ballerina.io/ballerinax/googleapis.drive/latest) connector and consumes that connector's own `ConnectionConfig` directly, so authentication is configured exactly as it is for the connector.

## Overview

`TextDataLoader` retrieves Drive files and converts each one into an `ai:TextDocument`, routing every file down one of **three lanes**:

- **Google Workspace native files** (Docs, Sheets, Slides) have no downloadable bytes, so they are **exported** to a textual format — a Doc/Slides to `text/plain`, a Sheet to `text/csv`.
- **Uploaded PDF and Microsoft Office files** (`pdf`, `docx`, `xlsx`, `pptx`, `doc`, `xls`, `ppt`) are **downloaded** and their text is extracted with [Apache Tika](https://tika.apache.org/) — PDFBox for PDFs, Apache POI for Office documents. (An uploaded `report.docx` is a different thing from a Google Doc: the former is extracted, the latter is exported.)
- **Textual binary files** (`txt`, `md`, `csv`, `json`, …) are **downloaded** and decoded as UTF-8.

Because Drive addresses everything by an opaque **ID** (a folder is just a file whose MIME type is `application/vnd.google-apps.folder`), sources are expressed by ID rather than by path.

## The ID-based `Source` model

Each `Source` selects content by ID **or by share URL**, in ways that may be combined:

| Field | Meaning |
| --- | --- |
| `folderId` | Load every supported file directly inside this folder. Set `recursive` to also descend into sub-folders. Trashed files are always excluded. |
| `folderUrl` | The folder's share URL (e.g. `https://drive.google.com/drive/folders/<id>`), as an alternative to `folderId` — the ID is extracted for you. Set **at most one** of `folderId`/`folderUrl`. |
| `fileIds` | Load these exact files by ID, regardless of folder. An explicitly named file is always loaded (subject to being a supported type) and **bypasses** `includeExtensions`. |
| `fileUrls` | Share URLs for individual files (e.g. `https://drive.google.com/file/d/<id>/view`, or a Docs `.../d/<id>/edit` URL), each resolved to its ID and **combined** with `fileIds`. |
| `recursive` | Whether sub-folders under the resolved folder are traversed (default `false`). |
| `includeExtensions` | Case-insensitive extension allowlist applied to **folder listings only**. Entries may include or omit a leading dot. Note: Workspace files have no extension, so an allowlist excludes them from listings. |

A source with none of `folderId`/`folderUrl`/`fileIds`/`fileUrls` loads nothing.

> **IDs vs URLs:** internally the loader is ID-based; the URL fields are a convenience that
> resolve a Drive share link to its ID via the exported `driveIdFromUrl(urlOrId)` function
> (which also passes a bare ID through unchanged, and errors on a URL with no recognisable ID).
> A folder ID is the last path segment of `https://drive.google.com/drive/folders/<id>`; a file
> ID is the `<id>` in `https://drive.google.com/file/d/<id>/view` (or `.../d/<id>/edit` for Docs
> Editors files, or the `id=` parameter of an `open?id=<id>` link). A link identifies a file but
> does **not** grant access — reading still requires that your OAuth2 credentials can see it.

## Return contract

`load()` returns a **bare** `ai:Document` when exactly one file is resolved, and an `ai:Document[]` otherwise (matching the `ai:DataLoader` contract).

## Supported, exported, and unsupported file types

| Category | Types | How |
| --- | --- | --- |
| **Exported** (Workspace natives) | Google Docs, Google Slides | `exportFile` → `text/plain` → used verbatim |
| **Exported** (Workspace natives) | Google Sheets | `exportFile` → `text/csv` (**first sheet only** — a Google limitation) |
| **Downloaded + decoded** | `txt`, `text`, `md`, `markdown`, `csv`, `tsv`, `json`, `xml`, `html`, `htm`, `yaml`, `yml`, `log`, `ini`, `conf`, `properties`, `css`, `js`, `ts`, plus any `text/*` MIME type | `getFileContent` → UTF-8 decode |
| **Downloaded + extracted** | `pdf` | `getFileContent` → Apache Tika (PDFBox) |
| **Downloaded + extracted** | uploaded Microsoft Office: `docx`, `xlsx`, `pptx` (OOXML) and `doc`, `xls`, `ppt` (legacy OLE2) | `getFileContent` → Apache Tika (POI) |
| **Unsupported (skipped/error)** | images, audio, other Google Apps types (Forms, Drawings, Sites, …), unknown binary | — |

An unsupported file found while **listing a folder** is skipped with a logged warning; the same file named **explicitly** in `fileIds` is an **error** (typo/intent detection).

### Text-less PDFs (scanned/image-only or blank)

A scanned PDF is page *images* in a PDF container, and a blank PDF has no content at all — in both cases PDFBox (which extracts only the text layer) parses "successfully" with zero text. Instead of silently producing an **empty** document the loader detects it:

- named **explicitly** in `fileIds` → an `ai:Error`: *"Failed to extract text from '…': the PDF contains no extractable text content (it may be a scanned/image-only document or an empty one); OCR is not supported"*;
- discovered in a **folder listing** → skipped with a logged warning (*"Skipping a PDF with no extractable text content"*, carrying the file name, file ID, and folder ID); the walk continues — one bad PDF never aborts a bulk load.

One neutral message covers both cases: without OCR the loader cannot tell a scan from a genuinely blank document, and both are equally unusable as text. Exported Google Docs/Sheets/Slides never hit this path — export returns text directly and is not parsed by PDFBox.

## Authentication

The loader consumes the connector's `drive:ConnectionConfig`, whose `auth` is either an OAuth2 refresh-token grant or a bearer token. To set up an OAuth2 refresh-token grant against Drive:

1. In the [Google Cloud Console](https://console.cloud.google.com/), create (or pick) a project and **enable the Google Drive API** (APIs & Services → Library → *Google Drive API* → Enable).
2. Configure the **OAuth consent screen** (User type *External* is fine for testing; add your Google account as a *Test user*).
3. Create an **OAuth client ID** credential of type *Desktop app* (or *Web application*). Note the **client ID** and **client secret**.
4. Grant the read-only Drive scope `https://www.googleapis.com/auth/drive.readonly` and obtain a **refresh token** — e.g. via the [OAuth 2.0 Playground](https://developers.google.com/oauthplayground/) (gear icon → *Use your own OAuth credentials* → paste client ID/secret → authorize the *Drive API v3* `drive.readonly` scope → *Exchange authorization code for tokens*).

```ballerina
import ballerina/ai;
import ballerinax/ai.google.drive;
import ballerinax/googleapis.drive as gdrive;

configurable string clientId = ?;
configurable string clientSecret = ?;
configurable string refreshToken = ?;

public function main() returns error? {
    gdrive:ConnectionConfig connectionConfig = {
        auth: {
            clientId,
            clientSecret,
            refreshToken,
            refreshUrl: "https://oauth2.googleapis.com/token"
        }
    };

    drive:TextDataLoader loader = check new (connectionConfig, [
        // Load a whole folder, descending into its sub-folders.
        {folderId: "1AbCdEfGhIjKlMnOpQrStUvWxYz", recursive: true},
        // Plus two specific files by ID (e.g. a Google Doc and a PDF).
        {fileIds: ["1DocId...", "1PdfId..."]},
        // …or paste share URLs directly — a folder link and a file link:
        {folderUrl: "https://drive.google.com/drive/folders/1FolderId..."},
        {fileUrls: ["https://drive.google.com/file/d/1FileId.../view"]}
    ]);

    ai:Document[]|ai:Document result = check loader.load();
    ai:Document[] documents = result is ai:Document[] ? result : [result];
    // Feed `documents` into a chunker / vector store …
}
```

## Reusing an existing client

`init` accepts **either** a `drive:ConnectionConfig` (shown above, where the loader builds and owns its client) **or** an already-constructed `drive:Client`. Pass a client when your application already talks to Drive — the loader then reuses that connection instead of creating a second HTTP connection pool and a second OAuth token-refresh cycle:

```ballerina
import ballerina/ai;
import ballerinax/ai.google.drive;
import ballerinax/googleapis.drive as gdrive;

// A client your application already created and uses elsewhere.
gdrive:Client driveClient = check new ({
    auth: {clientId, clientSecret, refreshToken, refreshUrl: "https://oauth2.googleapis.com/token"}
});

// Hand it to the loader instead of a config.
drive:TextDataLoader loader = check new (driveClient, [
    {folderId: "1AbCdEfGhIjKlMnOpQrStUvWxYz", recursive: true}
]);

ai:Document[]|ai:Document result = check loader.load();
```

> **Ownership:** a caller-supplied client is **not owned** by the loader — it is never closed or reconfigured, and its lifecycle stays yours. For an OAuth2 client, token acquisition and refresh also remain your responsibility; the loader only issues requests through the client it is given. (When you pass a `ConnectionConfig` instead, the loader owns the client it constructs.)

## Metadata

Each document's `ai:Metadata` is populated from the Drive file metadata: `fileName`, `mimeType` (the **original** Drive MIME type, even for exported Workspace files), `fileSize` (when Drive reports it — binary files and Google Docs; often absent for other Workspace files), `createdAt`, and `modifiedAt` (parsed from Drive's RFC 3339 timestamps). The opaque Drive `fileId` is retained as an extra metadata field.

## Limitations & open items

- **Google Sheets export is first-sheet only** (`text/csv`); additional sheets are not included.
- **Export size limit:** Google caps a single export at 10 MB.
- **Google Drawings/Forms/Sites** and other non-Docs/Sheets/Slides Workspace types have no supported textual export and are skipped.
- **No OCR.** Text-less PDFs (scanned/image-only or blank) are *detected* and reported (see
  above), not read — the loader ships no OCR engine. Future options, in rough order of fit for a Drive loader:
  **Google Drive's own OCR** (`files.copy` converting a PDF/image into a Google Doc with
  `ocrLanguage`, then exporting that Doc as text — stays inside the Drive API and quota);
  **Google Cloud Vision** (managed OCR; extra credentials/latency/pricing); or **Tesseract via
  Tika's OCR module** (free/local, but requires the native `tesseract` binary on every host —
  a deployment burden for a library).
- **Embedded objects inside Office files** (thumbnails, OLE attachments) are intentionally not
  recursed into — only the document's own text is extracted.
- **Duplicates are not de-duplicated:** the same file named twice in `fileIds`, or named
  explicitly *and* also reached through a loaded folder, yields one document per occurrence.
  De-duplication (if wanted) is the caller's responsibility.
- **One metadata call per loaded file:** because the connector's listing (`getAllFiles`)
  returns only `id`/`name`/`mimeType`, the loader issues a `getFile` per supported file to
  populate `fileSize`/`createdAt`/`modifiedAt`. Loading a very large folder therefore makes
  roughly one extra request per file — a rate-limit consideration, not a correctness issue.
- **Shared drives:** the underlying connector calls pass `supportsAllDrives`/`includeItemsFromAllDrives`, so files in shared drives are reachable by ID and shared-drive folders can be listed. Enumerating an entire shared drive by its *drive ID* (rather than a folder ID within it) is not a distinct feature of this loader and is not covered by the integration suite.
