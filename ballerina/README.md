# Ballerina Google Drive Data Loader

The `ballerinax/ai.google.drive` package provides a [`ai:DataLoader`](https://central.ballerina.io/ballerina/ai/latest) implementation that loads files from [Google Drive](https://www.google.com/drive/) and returns them as `ai:TextDocument`s — ready to chunk, embed, and index in a Ballerina AI / RAG pipeline.

The package is built on the [`ballerinax/googleapis.drive`](https://central.ballerina.io/ballerinax/googleapis.drive/latest) connector, so authentication and connection settings are configured exactly as they are for that connector, and a caller who already holds a `drive:Client` can hand it straight to the loader. The connector's own constraints are inherited along with it — see [Limitations](#limitations).

## Overview

`TextDataLoader` retrieves Drive files and converts each one into an `ai:TextDocument`, routing every file down one of **three lanes**:

- **Google Workspace native files** (Docs, Sheets, Slides) have no downloadable bytes, so they are **exported** to a textual format — a Doc/Slides to `text/plain`, a Sheet to `text/csv`.
- **Uploaded PDF and Microsoft Office files** (`pdf`, `docx`, `xlsx`, `pptx`, `doc`, `xls`, `ppt`) are **downloaded** and their text is extracted with [Apache Tika](https://tika.apache.org/) — PDFBox for PDFs, Apache POI for Office documents. (An uploaded `report.docx` is a different thing from a Google Doc: the former is extracted, the latter is exported.)
- **Textual binary files** (`txt`, `md`, `csv`, `json`, …) are **downloaded** and decoded to text.

Because Drive addresses everything by an opaque **ID** (a folder is just a file whose MIME type is `application/vnd.google-apps.folder`), sources are expressed by ID rather than by path.

## The ID-based `Source` model

Each `Source` lists what to load in `items`, by **ID or share URL** — either form, interchangeably, in any combination:

| Field | Meaning |
| --- | --- |
| `items` | The files and/or folders to load. Each entry is an ID **or** a share URL (`https://drive.google.com/file/d/<id>/view`, a Docs `.../d/<id>/edit` URL, or `https://drive.google.com/drive/folders/<id>`). A **file** entry becomes one document; a **folder** entry expands into every supported file directly inside it. Trashed items are always excluded. |
| `recursive` | Whether sub-folders under a folder entry are traversed (default `false`). No effect on file entries. |
| `includeExtensions` | Case-insensitive extension allowlist applied to the files **found inside a folder entry**. Entries may include or omit a leading dot. No effect on a file entry, which is named deliberately and so is never filtered out. Note: Workspace files have no extension, so an allowlist excludes them from listings. |

Drive draws no distinction between a file and a folder — a folder is simply a file with the folder MIME type, and both are addressed by the same kind of opaque ID — so `items` draws none either. Which entry is which is settled at **load** time from the Drive MIME type, not from where you put it.

Because `recursive` and `includeExtensions` shape how a *folder* entry expands, group entries that need different expansion settings into separate sources:

```ballerina
[
    {items: ["1SpecsFolderId"], recursive: true, includeExtensions: [".md"]},
    {items: ["1ReleaseNotesFolderId"]},          // top level only, all types
    {items: ["1DocId...", "1PdfId..."]}          // two individual files
]
```

A source with no `items` loads nothing, and logs a warning saying so.

Every source is validated when the loader is **constructed**, not when `load()` runs: each `items` entry is resolved to a Drive ID up front, so a configuration mistake fails immediately rather than part-way through a long load. Whether an ID names a file or a folder is *not* resolved then — that needs a Drive round trip, and its answer could be stale by the time `load()` runs.

> **IDs vs URLs:** internally the loader is ID-based; accepting a URL is a convenience — a bare
> ID is passed through unchanged, and a URL is reduced to the same ID. A folder ID is the last
> path segment of `https://drive.google.com/drive/folders/<id>`; a file ID is the `<id>` in
> `https://drive.google.com/file/d/<id>/view` (or `.../d/<id>/edit` for Docs Editors files, or
> the `id=` parameter of an `open?id=<id>` link). A link identifies a file but does **not** grant
> access — reading still requires that your credentials can see it.

## Return contract

`load()` returns a **bare** `ai:Document` when exactly one file is resolved, and an `ai:Document[]` otherwise (matching the `ai:DataLoader` contract).

## Supported, exported, and unsupported file types

| Category | Types | How |
| --- | --- | --- |
| **Exported** (Workspace natives) | Google Docs, Google Slides | export → `text/plain` → used verbatim |
| **Exported** (Workspace natives) | Google Sheets | export → `text/csv` (⚠️ **first sheet only** — see [Limitations](#limitations)) |
| **Downloaded + decoded** | `txt`, `text`, `md`, `markdown`, `csv`, `tsv`, `json`, `xml`, `yaml`, `yml`, `log`, `ini`, `conf`, `properties`, `css`, `js`, `ts`, plus any `text/*` MIME type | download → charset-aware decode |
| **Downloaded + rendered** | `html`, `htm`, `xhtml` | download → decode → markup rendered to plain text |
| **Downloaded + extracted** | `pdf` | download → Apache Tika (PDFBox) |
| **Downloaded + extracted** | uploaded Microsoft Office: `docx`, `xlsx`, `pptx` (OOXML) and `doc`, `xls`, `ppt` (legacy OLE2) | download → Apache Tika (POI) |
| **Unsupported (skipped/error)** | images, audio, video, archives, other Google Apps types (Forms, Drawings, Sites, …), unknown binary | — |
| **Unsupported: Drive shortcuts** | `application/vnd.google-apps.shortcut` | Not followed. A shortcut pointing at a supported file yields **no** document. |

The Drive **MIME type is authoritative** throughout: it decides both whether a file can be loaded and which parser reads it. The file-name extension is only a fallback for files whose MIME type is missing or generic (`application/octet-stream`). This matters in practice, because renaming a file in the Drive web UI drops its extension.

### Text decoding

Downloaded text is decoded using, in priority order: a byte-order mark, the charset Drive declares in the response `Content-Type`, then UTF-8. Any BOM is stripped rather than being carried into the document body — a leading `U+FEFF` would otherwise corrupt the first CSV header cell or the first Markdown heading. Decoding is **strict**: once the charset is known, bytes that still do not decode surface as an error rather than as replacement characters.

### Text-less PDFs (scanned/image-only or blank)

A scanned PDF is page *images* in a PDF container, and a blank PDF has no content at all — in both cases PDFBox (which extracts only the text layer) parses "successfully" with zero text. Instead of silently producing an **empty** document the loader detects it and reports it.

## Partial failure

The two selection modes differ deliberately:

- A file **discovered in a folder listing** that cannot be loaded — for any reason: a text-less PDF, content that will not decode, an export above Drive's size cap, a file flagged as abusive, a permissions error on that one file — is **skipped with a logged warning, and the walk continues**. One unreadable file never discards the documents already collected, nor abandons the rest of the folder. When anything was skipped, a per-folder summary records how many loaded and how many did not.
- An item **named explicitly** in `items` that cannot be loaded is an **`ai:Error`**. Naming something expresses intent, so failing to load it is a mistake worth reporting rather than a silent skip. This covers a missing or trashed ID, an unsupported file type, and content that will not decode or extract.

The same asymmetry applies to unsupported types and trashed files.

## Authentication

`drive:ConnectionConfig.auth` accepts the two shapes the connector supports:

| Auth | Use |
| --- | --- |
| `http:BearerTokenConfig` | A token you already hold. Constructs without contacting a token endpoint. |
| `http:OAuth2RefreshTokenGrantConfig` | Interactive/user-delegated access. |

> **No service-account auth.** The connector's `auth` field admits only those two, so a JWT
> bearer grant (`http:OAuth2JwtBearerGrantConfig`) — the usual shape for a service account with
> domain-wide delegation, and the natural fit for unattended ingestion — cannot be configured.
> Unattended loads need a long-lived refresh token instead.

### Required scopes

`https://www.googleapis.com/auth/drive.readonly` is the minimum, and is sufficient for everything this loader does (list, get metadata, download, export).

> ⚠️ **`drive.file` is NOT sufficient.** That scope only grants access to files your own app created or the user explicitly opened with it, so a loader pointed at pre-existing Drive content will see nothing.

### Setting up an OAuth2 refresh-token grant

1. In the [Google Cloud Console](https://console.cloud.google.com/), create (or pick) a project and **enable the Google Drive API** (APIs & Services → Library → *Google Drive API* → Enable).
2. Configure the **OAuth consent screen** (User type *External* is fine for testing; add your Google account as a *Test user*).
3. Create an **OAuth client ID** credential of type *Desktop app* (or *Web application*). Note the **client ID** and **client secret**.
4. Grant the `https://www.googleapis.com/auth/drive.readonly` scope and obtain a **refresh token** — e.g. via the [OAuth 2.0 Playground](https://developers.google.com/oauthplayground/) (gear icon → *Use your own OAuth credentials* → paste client ID/secret → authorize the *Drive API v3* `drive.readonly` scope → *Exchange authorization code for tokens*).

## Quickstart

```ballerina
import ballerina/ai;
import ballerina/io;
import ballerinax/ai.google.drive;

configurable string clientId = ?;
configurable string clientSecret = ?;
configurable string refreshToken = ?;

public function main() returns error? {
    drive:ConnectionConfig connectionConfig = {
        auth: {
            clientId,
            clientSecret,
            refreshToken,
            refreshUrl: "https://oauth2.googleapis.com/token"
        }
    };

    drive:TextDataLoader loader = check new (connectionConfig, [
        // A whole folder, descending into its sub-folders, plus two individual files
        // (e.g. a Google Doc and a PDF) — folders and files go in the same list.
        {items: ["1AbCdEfGhIjKlMnOpQrStUvWxYz", "1DocId...", "1PdfId..."], recursive: true},
        // …or paste share URLs directly — the same field accepts them, either kind:
        {items: [
            "https://drive.google.com/drive/folders/1FolderId...",
            "https://drive.google.com/file/d/1FileId.../view"
        ]}
    ]);

    ai:Document[]|ai:Document result = check loader.load();
    ai:Document[] documents = result is ai:Document[] ? result : [result];
    io:println(string `Loaded ${documents.length()} document(s)`);
}
```

### Reusing a client you already hold

If your program already talks to Drive through the connector, pass that client instead of a
config. The loader then adds no second HTTP connection pool and no second OAuth refresh cycle:

```ballerina
drive:Client existingClient = check new (connectionConfig);
// … your own Drive calls …

drive:TextDataLoader loader = check new (existingClient, [
    {items: ["1SpecsFolderId"], recursive: true}
]);
```

A supplied client is **not owned** by the loader: it is never closed or reconfigured, and token
acquisition and refresh stay your concern. Note that the retry and response-limit defaults
described under [Configuration](#configuration) are applied only when the loader builds the
client itself — a client you construct carries whatever you configured on it.

### Feeding a knowledge base

`ai:KnowledgeBase.ingest` accepts `ai:Document[]|ai:Document` directly, and `load()` returns
exactly that, so the hand-off is one line. The fragment below assumes a `vectorStore` and an
`embeddingModel` — those come from provider packages (a vector-store connector and an embedding
provider), not from `ballerina/ai` itself, so substitute the ones you use:

```ballerina
drive:TextDataLoader loader = check new (connectionConfig, [
    {items: ["1SpecsFolderId"], recursive: true}
]);

// `AUTO` lets the knowledge base pick a chunker per document type — Markdown loaded from Drive
// gets `ai:MarkdownChunker`, rendered HTML gets `ai:HtmlChunker`, and so on. Pass an explicit
// `ai:Chunker` instead if you want to control chunking yourself.
ai:KnowledgeBase knowledgeBase = new ai:VectorKnowledgeBase(vectorStore, embeddingModel);
check knowledgeBase.ingest(check loader.load());

ai:QueryMatch[] matches = check knowledgeBase.retrieve("What is the Q3 revenue target?", 5);
```

## Configuration

Configuration is the connector's `drive:ConnectionConfig`. Two of its fields are optional and
unset by default, which would leave a bulk load with no retry at all over Drive's throttling and
an unbounded response body; the loader fills both in when you supply neither. An explicit value
always wins — including one that deliberately disables retrying.

| Field | Applied default | Purpose |
| --- | --- | --- |
| `retryConfig` | 4 attempts, 1s interval, ×2 backoff, capped at 20s, over `[403, 429, 500, 502, 503, 504]` | Google [requires exponential backoff](https://developers.google.com/workspace/drive/api/guides/handle-errors) for rate limiting. Drive reports throttling as **403** `rateLimitExceeded` as well as 429, and `http:RetryConfig` can only match on status code — so a genuine permissions 403 is also retried before it fails. |
| `responseLimits` | `maxEntityBodySize` 100 MiB | Bounds a download. Unset, this defaults to unlimited. |

The remaining fields (`timeout`, `httpVersion`, `poolConfig`, `secureSocket`, `proxy`, …) are the
connector's own and are passed through untouched. Your `drive:ConnectionConfig` record is never
mutated — the defaults are applied to a copy.

### Tuning retries for folders with inaccessible files

Because a permissions 403 is indistinguishable from a throttling 403 at the status-code level, an
inaccessible file costs the full retry ladder (~15s: 1 + 2 + 4 + 8) before it is skipped. That is
paid per file, so a folder where many files are not shared with you loads slowly while still
returning the same documents. If you hit that — and you are not loading enough at once to be
throttled — supply a shorter ladder, or drop 403 from the retried statuses:

```ballerina
drive:ConnectionConfig config = {
    auth: {...},
    // Retry only unambiguous transient failures; fail an inaccessible file immediately.
    retryConfig: {
        interval: 1,
        count: 4,
        backOffFactor: 2.0,
        maxWaitInterval: 20,
        statusCodes: [429, 500, 502, 503, 504]
    }
};
```

The trade-off runs the other way too: without 403, a bulk load that *does* get rate-limited loses
its retry over Drive's most common throttle signal. Keep the default unless slow folder loads are
an observed problem.

## Metadata

Each document's `ai:Metadata` is populated from the Drive file metadata:

| Field | Source |
| --- | --- |
| `fileName` | Drive `name` |
| `mimeType` | The **original** Drive MIME type, even for exported Workspace files |
| `fileSize` | The downloaded byte count for a binary download. **Unset for exported Workspace files** — an export's length is not the source file's size. Drive's own `size` field is not used; see [Limitations](#limitations). |
| `createdAt`, `modifiedAt` | Parsed from Drive's RFC 3339 timestamps |
| `fileId` | The opaque Drive ID, retained as an extra field so a document can be traced back to its source |
| `webUrl` | Drive's `webViewLink` — a citation URL back to the document |

## Limitations

- ⚠️ **Google Sheets lose every sheet but the first.** Sheets are exported as `text/csv`, which Google documents as [first-sheet-only](https://developers.google.com/workspace/drive/api/guides/ref-export-formats). A multi-tab spreadsheet is loaded with tabs 2..N **silently discarded** — no warning, no error. If your corpus contains multi-tab spreadsheets, this is data loss you need to know about.
- **Drive shortcuts are not followed.** A folder containing only shortcuts loads zero documents. `shortcutDetails.targetId` is not requested or resolved.
- **Export size limit:** Google caps a single export at 10 MB. This applies only to Workspace natives (Docs/Sheets/Slides). An export that exceeds it is reported by name rather than as raw Drive JSON.
- **No OCR.** Text-less PDFs (scanned/image-only or blank) are *detected* and reported, not read — the loader ships no OCR engine.
- **GraalVM native image is not supported yet.** `graalvmCompatible` is `false`: the Apache POI / XMLBeans / Tika stack is reflection- and resource-driven, and the native-image metadata for it has not been generated and verified.
- **No de-duplication.** The same file named twice in `items`, or named explicitly *and* also reached through a loaded folder, yields one document per occurrence.
- **No cycle or depth guard on recursion.** Drive has been single-parent since 2020, so a folder cycle is not constructible today, but there is no `maxDepth` limit.
- **Embedded objects inside Office files** (thumbnails, OLE attachments) are intentionally not recursed into — only the document's own text is extracted.
- **Encrypted or password-protected documents** are not decrypted.
- **Shared drives:** the connector passes `supportsAllDrives`/`includeItemsFromAllDrives` on the calls the loader makes, so files in shared drives are reachable by ID and shared-drive folders can be listed. Enumerating an entire shared drive by its *drive ID* (rather than a folder ID within it) is not a feature of this loader.

### Inherited from the `googleapis.drive` connector

These follow from building on the connector rather than on the Drive REST API directly:

- **No size ceiling before download.** Drive serialises `size` as a JSON string (it is an int64) but the connector types `File.size` as `int`, so requesting the field breaks the connector's response binding. The field therefore cannot be requested at all, and a file's size is only known once it has been downloaded. `ai:Metadata.fileSize` is derived from the downloaded byte count instead. Memory is bounded by `responseLimits.maxEntityBodySize`, not by a per-file check.
- **One extra request per file.** `getAllFiles` accepts no field mask, so a listing returns only Drive's default projection (id/name/mimeType/kind). The timestamps `ai:Metadata` needs cost one `files.get` per file that becomes a document — an N+1 that cannot be avoided through the connector.
- **`incompleteSearch` is not surfaced.** When Drive cannot search every corpus it flags the listing as partial. The connector's listing stream drops that flag, so a partial ingestion is indistinguishable from a complete one.
- **No `acknowledgeAbuse`.** A file Drive has flagged as abusive cannot be downloaded through the connector at all. The refusal is reported by name, but there is no way to override it.
- **Coarser errors.** The connector rebuilds every Drive failure as `error(<response body>)`, discarding the HTTP status code and the original error as a cause. A missing file is therefore recognised by matching Drive's `notFound` reason in the message rather than by status code.
- **No `serviceUrl`.** The connector hardcodes `https://www.googleapis.com` as a module-private constant, so the loader cannot be pointed at a mock service. Traversal, routing, and partial-failure behaviour are consequently **not covered by automated tests** — only the pure logic around them is (classification, URL parsing, decoding, extraction, metadata mapping, error translation). See the test-coverage note below.

### Test coverage

The unit-testable layers are well covered, but the code that walks Drive is not: with no way to
redirect the connector at a test server, `load()` cannot be exercised without live credentials.
`drive_data_loader.bal` sits at roughly 20% line coverage as a result.
