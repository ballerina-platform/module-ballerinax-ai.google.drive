// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/http;
import ballerina/jballerina.java;
import ballerina/time;
import ballerinax/googleapis.drive;

// How a Drive file is fetched and turned into text, derived primarily from its Drive
// MIME type (which is always available) and, for ordinary binary files, its extension.
//
// The central difference from a plain filesystem loader is the split between the two
// FETCH strategies: Google Workspace native files (Docs/Sheets/Slides) have no
// downloadable bytes and must be EXPORTED to a textual format, whereas ordinary binary
// files (pdf, txt, csv, …) are DOWNLOADED as-is. `classify` encodes both the fetch
// strategy and the subsequent text strategy in a single value.
enum FileClass {
    // Ordinary binary file that is inherently textual; downloaded and decoded from bytes.
    TEXT_DOWNLOAD,
    // An uploaded binary document whose text is extracted via Apache Tika after download —
    // a PDF (PDFBox) or a Microsoft Office file (.doc/.docx, .ppt/.pptx, .xls/.xlsx; Apache
    // POI). These are ordinary uploaded blobs, distinct from Google Workspace natives.
    EXTRACT_DOWNLOAD,
    // A Google Doc or Google Slides deck; EXPORTED to `text/plain`, then used verbatim.
    WORKSPACE_TEXT,
    // A Google Sheet; EXPORTED to `text/csv` (first sheet only — a Google limitation).
    WORKSPACE_CSV,
    // Cannot be represented as text (images, other Google Apps types such as Forms/Drawings,
    // unknown binary); skipped in folder loads, rejected when named explicitly.
    UNSUPPORTED
}

// Google Workspace (Docs Editors) native MIME types. Files with these types hold no
// downloadable blob content and MUST be retrieved via `exportFile`, never `getFileContent`.
const string GOOGLE_APPS_PREFIX = "application/vnd.google-apps.";
const string GOOGLE_DOC_MIME = "application/vnd.google-apps.document";
const string GOOGLE_SHEET_MIME = "application/vnd.google-apps.spreadsheet";
const string GOOGLE_SLIDES_MIME = "application/vnd.google-apps.presentation";
// The Drive MIME type identifying a folder (a folder is just a file of this type).
const string GOOGLE_FOLDER_MIME = "application/vnd.google-apps.folder";

// Workspace export target MIME types. Docs/Slides export cleanly to plain text; Sheets
// export to CSV (first sheet only). These are the target formats passed to `exportFile`.
const string EXPORT_MIME_TEXT = "text/plain";
const string EXPORT_MIME_CSV = "text/csv";

# Classifies a Drive file by how its text is obtained. The Drive MIME type is authoritative
# and is checked first (Workspace native types, then binary types); the file-name extension
# is a fallback for binary files whose MIME type is missing or generic.
#
# + mimeType - the file's Drive MIME type (`()` if unknown)
# + fileName - the file name, used for extension fallback
# + return - the file's class
isolated function classify(string? mimeType, string fileName) returns FileClass {
    string mime = (mimeType ?: "").toLowerAscii();

    // Google Workspace native files: routed to the EXPORT path. The MIME type is the only
    // reliable signal here (these files have no meaningful extension).
    if mime == GOOGLE_DOC_MIME || mime == GOOGLE_SLIDES_MIME {
        return WORKSPACE_TEXT;
    }
    if mime == GOOGLE_SHEET_MIME {
        return WORKSPACE_CSV;
    }
    // Any other Google Apps type (Forms, Drawings, Sites, Maps, shortcuts, …) has no
    // supported textual export, so it is skipped/rejected.
    if mime.startsWith(GOOGLE_APPS_PREFIX) {
        return UNSUPPORTED;
    }

    // Ordinary binary file: classify by MIME type, then extension.
    string extension = getExtension(fileName);
    if mime.startsWith("text/") || (mime != "" && TEXT_MIME_TYPES.indexOf(mime) !is ())
            || TEXT_EXTENSIONS.indexOf(extension) !is () {
        return TEXT_DOWNLOAD;
    }
    // PDFs and uploaded Microsoft Office documents are downloaded and text-extracted via
    // Apache Tika (PDFBox for PDF, POI for Office). Google Workspace natives were already
    // routed to the EXPORT path above, so they never reach this Tika lane.
    if (mime != "" && EXTRACTABLE_MIME_TYPES.indexOf(mime) !is ())
            || EXTRACTABLE_EXTENSIONS.indexOf(extension) !is () {
        return EXTRACT_DOWNLOAD;
    }
    return UNSUPPORTED;
}

# Returns the export target MIME type for a Workspace file class, or `()` for classes that
# are downloaded rather than exported. Used by the loader to route `exportFile` calls.
#
# + fileClass - the classification of the file
# + return - the export MIME type, or `()` if the file is not exported
isolated function exportMimeTypeFor(FileClass fileClass) returns string? {
    match fileClass {
        WORKSPACE_TEXT => {
            return EXPORT_MIME_TEXT;
        }
        WORKSPACE_CSV => {
            return EXPORT_MIME_CSV;
        }
    }
    return ();
}

# Reports whether a file class is retrieved via `exportFile` (Workspace) rather than
# `getFileContent` (ordinary binary download).
#
# + fileClass - the classification of the file
# + return - `true` when the file must be exported
isolated function requiresExport(FileClass fileClass) returns boolean =>
    fileClass == WORKSPACE_TEXT || fileClass == WORKSPACE_CSV;

# Reports whether a file class can be loaded as a text document at all (the four supported
# classes). The `UNSUPPORTED` class cannot.
#
# + fileClass - the classification of the file
# + return - `true` when the file yields a text document
isolated function isSupported(FileClass fileClass) returns boolean =>
    fileClass == TEXT_DOWNLOAD || fileClass == EXTRACT_DOWNLOAD || requiresExport(fileClass);

# Builds an `ai:TextDocument` from fetched content (downloaded bytes or an exported blob),
# extracting the text of PDF and Microsoft Office documents via Apache Tika and decoding
# everything else as text. Only ever called for a supported class (see `isSupported`).
#
# Decoding honours a byte-order mark first, then `contentType`'s charset, then UTF-8, and
# strips any BOM (see `decodeText`). HTML is rendered to plain text rather than stored as raw
# markup, so tags and character references never reach the document body.
#
# + content - the fetched bytes (a binary download, or the export result)
# + fileClass - how the bytes should be turned into text
# + metadata - the document metadata to attach
# + contentType - the `Content-Type` of the fetched bytes, whose `charset` parameter is used
#                 when the content carries no BOM (`""` when unknown; exports are UTF-8)
# + return - the built document, or an `ai:Error` if the content cannot be decoded/extracted,
#            including the descriptive error for a text-less (scanned or blank) PDF
isolated function buildDocument(byte[] content, FileClass fileClass, ai:Metadata metadata,
        string contentType = "") returns ai:TextDocument|ai:Error {
    string fileName = metadata.fileName ?: "<unnamed>";
    if fileClass == EXTRACT_DOWNLOAD {
        // The MIME type is what routed this file to the Tika lane, so it also picks the
        // parser; the name is only a fallback (Drive files are often renamed extension-less).
        string|error text = extractText(content, fileName, metadata.mimeType ?: "");
        if text is error {
            return error ai:Error(
                string `Failed to extract text from '${fileName}': ${text.message()}`, text);
        }
        return {content: text, metadata};
    }
    // TEXT_DOWNLOAD, WORKSPACE_TEXT and WORKSPACE_CSV all yield text bytes.
    string|error text = decodeText(content, charsetFromContentType(contentType));
    if text is error {
        return error ai:Error(
            string `Failed to decode text content of '${fileName}': ${text.message()}`, text);
    }
    // An HTML file is textually meaningful only once its markup is rendered away; leaving the
    // tags in place injects markup tokens into every embedding downstream.
    if isHtml(metadata.mimeType ?: "", fileName) {
        return {content: htmlToText(text), metadata};
    }
    return {content: text, metadata};
}

# Extracts the `charset` parameter from a `Content-Type` header value, or `""` when absent.
# Drive reports the charset it detected for a downloaded text blob there.
#
# + contentType - the `Content-Type` value (e.g. `text/plain; charset=UTF-16LE`)
# + return - the charset name, or `""` when the header declares none
isolated function charsetFromContentType(string contentType) returns string {
    int? charsetIndex = contentType.toLowerAscii().indexOf("charset=");
    if charsetIndex is () {
        return "";
    }
    string rest = contentType.substring(charsetIndex + "charset=".length());
    // The charset parameter may be followed by further parameters, and may be quoted.
    int? separator = rest.indexOf(";");
    string charset = separator is int ? rest.substring(0, separator) : rest;
    return re `"`.replaceAll(charset.trim(), "");
}

# Reports whether a file is HTML, so its markup can be rendered to text. Checks the Drive MIME
# type first (authoritative, as in `classify`), then the file-name extension.
#
# + mimeType - the Drive MIME type
# + fileName - the file name
# + return - `true` when the content should be treated as HTML markup
isolated function isHtml(string mimeType, string fileName) returns boolean {
    string mime = mimeType.toLowerAscii();
    if mime.startsWith("text/html") || mime.startsWith("application/xhtml+xml") {
        return true;
    }
    if mime != "" && !mime.startsWith("application/octet-stream") {
        return false;
    }
    string extension = getExtension(fileName);
    return extension == "html" || extension == "htm" || extension == "xhtml";
}

# Builds `ai:Metadata` from a Drive file resource. Drive surfaces a real MIME type and RFC 3339
# timestamps, so `mimeType`, `createdAt` and `modifiedAt` are populated here (guarding for
# missing/unparseable values).
#
# `fileSize` is NOT set here: Drive's `size` cannot be requested through the connector (see
# `FILE_FIELDS`), so the caller fills it in from the downloaded byte count for ordinary files and
# leaves it unset for exported Workspace files, whose export length is not the source file's size.
#
# + file - the Drive file metadata
# + return - the assembled metadata
isolated function buildMetadata(drive:File file) returns ai:Metadata {
    ai:Metadata metadata = {};
    string? name = file.name;
    if name is string {
        metadata.fileName = name;
    }
    string? mimeType = file.mimeType;
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    // A link back to the document in Drive: for a RAG pipeline this is the citation URL, and
    // Drive returns it in the same response, so there is no extra cost to carrying it.
    string? webViewLink = file.webViewLink;
    if webViewLink is string {
        metadata["webUrl"] = webViewLink;
    }
    time:Utc? createdAt = toUtc(file.createdTime);
    if createdAt is time:Utc {
        metadata.createdAt = createdAt;
    }
    time:Utc? modifiedAt = toUtc(file.modifiedTime);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }
    // Retain the opaque Drive ID as an extra field so callers can trace a document back to
    // its source file (Drive addresses everything by ID, so this is the durable key).
    string? id = file.id;
    if id is string {
        metadata["fileId"] = id;
    }
    return metadata;
}

# Reports whether an error denotes a missing file/folder, used to turn a mistyped file/folder ID
# into a clear "not found" error.
#
# The typed `http:ClientRequestError` status code is checked first, walking the cause chain since
# the error may be wrapped. It is the only unambiguous signal. Only when no status code is present
# does this fall back to matching Drive's `notFound` reason and its "File not found" text.
#
# In practice the fallback is what runs today: the `googleapis.drive` connector rebuilds every
# Drive failure as `error(<response json>.toString())`, discarding both the status code and the
# original error as a cause. That stringified body does still carry Drive's `notFound` reason, so
# the match holds. The status-code branch is kept because it is the correct signal whenever an
# error does reach here with one attached.
#
# A bare `"404"` substring is deliberately NOT matched: it appears in messages that have nothing
# to do with a missing file — a quota error whose help URL ends in `#404`, or any message quoting
# a file named `Report-404.pdf` — and would produce a wrong diagnostic.
#
# + err - the error to test
# + return - `true` when the error denotes a missing file or folder
isolated function isNotFoundError(error err) returns boolean {
    int? status = statusCodeOf(err);
    if status is int {
        return status == http:STATUS_NOT_FOUND;
    }
    string message = err.message().toLowerAscii();
    return message.includes("file not found") || message.includes("notfound")
        || message.includes("not found");
}

# Extracts the HTTP status code from an error, walking the cause chain. Returns `()` when the
# error carries no status code at all.
#
# + err - the error to inspect
# + return - the HTTP status code, or `()` if none is present
isolated function statusCodeOf(error err) returns int? {
    error? current = err;
    while current is error {
        if current is http:ClientRequestError {
            return current.detail().statusCode;
        }
        if current is http:RemoteServerError {
            return current.detail().statusCode;
        }
        current = current.cause();
    }
    return ();
}

# Extracts plain text from a PDF or Microsoft Office document using Apache Tika, reading
# directly from the in-memory bytes (no temporary file).
#
# `mimeType` selects the parser (PDFBox for `application/pdf`; POI's OOXML parser for the
# `openxmlformats-officedocument.*` types and OLE2 parser for `application/msword`,
# `application/vnd.ms-excel`, `application/vnd.ms-powerpoint`), matching `classify`, which
# also treats the Drive MIME type as authoritative. `fileName` is the fallback when the MIME
# type is unknown or generic, and is passed to Tika as a resource-name hint either way.
#
# Returns an `error` if the content cannot be parsed, or if a PDF parses but contains no
# extractable text (a scanned / image-only document, or a blank one) — see
# `TEXTLESS_PDF_REASON` / `isTextlessPdfError`.
#
# + content - the raw document bytes
# + fileName - the file name (parser fallback; a Tika hint)
# + mimeType - the Drive MIME type, which selects the parser (`""` when unknown)
# + return - the extracted text, or an `error` on failure
isolated function extractText(byte[] content, string fileName, string mimeType)
        returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.google.drive.TextExtractor",
    name: "extractText"
} external;

# Decodes fetched text bytes. The charset is resolved from a byte-order mark first (which is
# authoritative and self-describing), then from `charset`, then UTF-8; any BOM is stripped so
# it never reaches the document body. Decoding is strict, so genuinely corrupt content still
# surfaces as an error rather than as replacement characters.
#
# + content - the raw text bytes
# + charset - the charset Drive declared (`""` when unknown)
# + return - the decoded text, or an `error` if the bytes are invalid in that charset
isolated function decodeText(byte[] content, string charset) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.google.drive.TextDecoder",
    name: "decodeText"
} external;

# Renders HTML markup as plain text: drops script/style bodies and comments, turns block
# boundaries into line breaks, strips the remaining tags and resolves character references.
#
# + html - the raw HTML source
# + return - the rendered plain text
isolated function htmlToText(string html) returns string = @java:Method {
    'class: "io.ballerina.lib.ai.google.drive.TextDecoder",
    name: "htmlToText"
} external;

// The structured `reason` the native extractor attaches when a PDF parses successfully but
// yields no text — either a scanned/image-only document or a genuinely blank one. Mirrors
// TEXTLESS_PDF_REASON in TextExtractor.java. This is a data contract, not a message contract:
// rewording the human-readable message cannot change how the loader behaves.
const string TEXTLESS_PDF_REASON = "TEXTLESS_PDF";

# Reports whether an error denotes a text-less PDF (scanned/image-only or blank). The loader
# uses this to skip such files in folder listings (with a warning) — like other non-text
# content — while an explicitly named text-less PDF surfaces the descriptive error to the
# caller.
#
# The whole cause chain is inspected because the extraction error is wrapped by
# `buildDocument` before it reaches the loader, which puts the native error one level down.
#
# + err - the error to test
# + return - `true` when the error (or one of its causes) carries the text-less-PDF reason
isolated function isTextlessPdfError(error err) returns boolean {
    error? current = err;
    while current is error {
        var reason = current.detail()["reason"];
        if reason is string && reason == TEXTLESS_PDF_REASON {
            return true;
        }
        current = current.cause();
    }
    return false;
}

# Returns the lower-cased file extension (without the dot), or `""` if none.
#
# + fileName - the file name
# + return - the lower-cased extension without the leading dot
isolated function getExtension(string fileName) returns string {
    int? lastDotIndex = fileName.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return fileName.substring(lastDotIndex + 1).toLowerAscii();
}

# Reports whether a file passes the extension allowlist (`()`/empty matches all). Entries are
# case-insensitive and a leading dot is optional. Applied only to folder listings.
#
# + fileName - the file name to test
# + includeExtensions - the allowlist, or `()`/`[]` to allow everything
# + return - `true` when the file is allowed
isolated function matchesExtensionFilter(string fileName, string[]? includeExtensions) returns boolean {
    if includeExtensions is () || includeExtensions.length() == 0 {
        return true;
    }
    string extension = getExtension(fileName);
    foreach string allowed in includeExtensions {
        string normalized = allowed.toLowerAscii();
        if normalized.startsWith(".") {
            normalized = normalized.substring(1);
        }
        if normalized == extension {
            return true;
        }
    }
    return false;
}

# Parses an RFC 3339 timestamp (as Drive reports `createdTime`/`modifiedTime`) into
# `time:Utc`, or `()` if absent/unparseable. Drive timestamps look like
# `2024-01-15T10:30:00.000Z`, which `time:utcFromString` accepts.
#
# + dateTime - the timestamp string, or `()`
# + return - the parsed `time:Utc`, or `()` when absent/unparseable
isolated function toUtc(string? dateTime) returns time:Utc? {
    if dateTime is () {
        return ();
    }
    time:Utc|error utc = time:utcFromString(dateTime);
    return utc is time:Utc ? utc : ();
}

# Extracts the opaque Drive file/folder ID from a share URL. A value that is already a bare ID
# (no path or query separators) is returned unchanged, so callers may pass either form. The
# common Drive URL shapes are handled:
#
# - `https://drive.google.com/file/d/<ID>/view` (uploaded files)
# - `https://docs.google.com/{document,spreadsheets,presentation}/d/<ID>/edit` (Docs/Sheets/Slides)
# - `https://drive.google.com/drive/folders/<ID>` (folders)
# - `https://drive.google.com/open?id=<ID>` (and any `?id=`/`&id=` query form)
#
# Surrounding query parameters (`?usp=sharing`, `#gid=0`, …) are stripped.
#
# + urlOrId - a Drive share URL, or a bare Drive ID
# + return - the extracted ID, or an `ai:Error` if no ID could be found in a URL-shaped value
isolated function driveIdFromUrl(string urlOrId) returns string|ai:Error {
    string value = urlOrId.trim();
    if value == "" {
        return error ai:Error("Cannot extract a Google Drive ID from an empty string");
    }
    // A bare ID has no path or query separators — return it unchanged.
    if !value.includes("/") && !value.includes("?") {
        return value;
    }
    // `/d/<id>/…` covers uploaded files and every Docs Editors type (document/spreadsheets/
    // presentation), then `/folders/<id>`, then the `?id=<id>` / `&id=<id>` query form.
    string? fromPath = idAfter(value, "/d/");
    if fromPath is string {
        return fromPath;
    }
    string? fromFolder = idAfter(value, "/folders/");
    if fromFolder is string {
        return fromFolder;
    }
    string? fromQuery = idAfter(value, "?id=") ?: idAfter(value, "&id=");
    if fromQuery is string {
        return fromQuery;
    }
    return error ai:Error(string `Could not extract a Google Drive file or folder ID from '${urlOrId}'`);
}

// Returns the token immediately after `marker` in `value`, up to the next path/query
// delimiter (`/`, `?`, `&`, `#`), or `()` when the marker is absent or the token is empty.
isolated function idAfter(string value, string marker) returns string? {
    int? markerIndex = value.indexOf(marker);
    if markerIndex is () {
        return ();
    }
    string rest = value.substring(markerIndex + marker.length());
    int end = rest.length();
    foreach string delimiter in ["/", "?", "&", "#"] {
        int? delimiterIndex = rest.indexOf(delimiter);
        if delimiterIndex is int && delimiterIndex < end {
            end = delimiterIndex;
        }
    }
    string id = rest.substring(0, end);
    return id == "" ? () : id;
}

// MIME types (outside the `text/` family) treated as text.
final readonly & string[] TEXT_MIME_TYPES = [
    "application/json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/x-yaml",
    "application/yaml",
    "application/csv"
];

// File extensions treated as text.
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js", "ts"
];

// MIME types whose text is extracted via Apache Tika after download: PDF (PDFBox) and
// uploaded Microsoft Office documents (POI, via the `tika-parser-microsoft-module`). These
// are the MIME types Drive reports for *uploaded* binary blobs — Google Workspace natives
// carry `application/vnd.google-apps.*` types and are routed to the EXPORT path in `classify`
// before this list is consulted.
final readonly & string[] EXTRACTABLE_MIME_TYPES = [
    "application/pdf",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
];

// File extensions whose text is extracted via Apache Tika: PDF and Microsoft Office.
final readonly & string[] EXTRACTABLE_EXTENSIONS = [
    "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx"
];
