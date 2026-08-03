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
import ballerina/log;
import ballerinax/googleapis.drive;

# A data loader that retrieves documents from Google Drive as text.
#
# Google Workspace native files (Docs/Sheets/Slides) are exported to a textual format
# (`text/plain` / `text/csv`); ordinary binary files (pdf, txt, md, csv, …) are downloaded.
# PDFs and uploaded Microsoft Office documents have their text extracted via Apache Tika.
# See the module documentation for the ID-based `Source` model and the supported/exported/
# unsupported file types.
@display {
    label: "Google Drive Text Data Loader"
}
public isolated class TextDataLoader {
    *ai:DataLoader;

    private final drive:Client driveClient;
    private final readonly & ResolvedSource[] sources;

    # Initializes the Google Drive data loader.
    #
    # The connection may be given in either of two forms:
    #
    # - a `drive:ConnectionConfig` (OAuth2 refresh-token grant or a bearer token) — the loader
    #   constructs and owns its own connector client; or
    # - an already-constructed `drive:Client` — the loader reuses it, so a caller that already
    #   talks to Drive does not pay for a second HTTP connection pool or a second OAuth token
    #   refresh cycle.
    #
    # A caller-supplied client is **not owned** by the loader: the loader never closes or
    # reconfigures it, and the caller remains responsible for its lifecycle. For an OAuth2
    # client, token acquisition and refresh likewise stay the caller's concern — the loader
    # only issues requests through the client it is given.
    #
    # Every source is fully validated here rather than at load time: each `folder`/`files` entry
    # is resolved to a Drive ID, so a source naming an unparseable share URL fails immediately
    # instead of part-way through a long load, after documents have already been fetched and
    # then discarded.
    #
    # + driveConnection - The Google Drive connector configuration shared by all sources, or an
    #                     existing `drive:Client` to reuse (not owned by the loader)
    # + sources - One or more Drive folders and/or file IDs to load documents from
    # + return - An `ai:Error` if the connection could not be established or a source is invalid
    public isolated function init(
            @display {label: "Connection"} drive:ConnectionConfig|drive:Client driveConnection,
            @display {label: "Data Sources"} Source[] sources) returns ai:Error? {
        // Validated before the connection is resolved, so it applies to both forms.
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the Google Drive data loader");
        }
        ResolvedSource[] resolved = [];
        foreach Source src in sources {
            string? folderId = check resolveFolderId(src);
            string[] fileIds = check resolveFileIds(src);
            // A source that names nothing loads nothing. Silently returning zero documents here
            // while an empty `sources` array is a hard error would give the caller the same
            // outcome from a clear failure in one case and total silence in the other.
            if folderId is () && fileIds.length() == 0 {
                log:printWarn("A Google Drive source selects nothing and will load no documents; " +
                        "set 'folder' or 'files'");
            }
            resolved.push({
                folderId,
                fileIds,
                recursive: src.recursive,
                includeExtensions: src.includeExtensions
            });
        }
        self.sources = resolved.cloneReadOnly();
        self.driveClient = driveConnection is drive:Client
            ? driveConnection
            : check newDriveClient(driveConnection);
    }

    # Loads the configured Google Drive documents.
    #
    # + return - The loaded document when a single file is resolved, an array of documents
    #            otherwise, or an `ai:Error` on failure
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        // Sources arrive already resolved to Drive IDs (see `init`), so the load path is purely
        // ID-based and cannot fail on a configuration mistake half-way through.
        foreach ResolvedSource src in self.sources {
            // Explicitly named files are always loaded (subject to being a supported type) and
            // bypass the extension filter — the filter applies to folder listings only.
            foreach string fileId in src.fileIds {
                ai:TextDocument document = check self.loadNamedFile(fileId);
                documents.push(document);
            }
            string? folderId = src.folderId;
            if folderId is string {
                ai:Document[] loaded = check self.loadFolder(folderId, src.recursive, src.includeExtensions);
                documents.push(...loaded);
            }
        }
        if documents.length() == 1 {
            return documents[0];
        }
        return documents;
    }

    // Loads a single explicitly named file by ID. Unlike a file discovered in a folder
    // listing, a deliberately named non-text/Office/trashed file is an ERROR (typo/intent
    // detection), not a silent skip.
    private isolated function loadNamedFile(string fileId) returns ai:TextDocument|ai:Error {
        drive:File file = check self.getFileMetadata(fileId);
        if file.trashed == true {
            return error ai:Error(string `File ID '${fileId}' is in the trash and cannot be loaded`);
        }
        // A folder ID in `files` classifies as UNSUPPORTED, so without this it would be
        // reported as an unsupported file type — true but unhelpful. Name the actual mistake.
        if file.mimeType == GOOGLE_FOLDER_MIME {
            return error ai:Error(string `The ID '${fileId}' refers to a folder, not a file; ` +
                string `use 'folder' to load a folder's contents`);
        }
        FileClass fileClass = classify(file.mimeType, file.name ?: "");
        if !isSupported(fileClass) {
            return error ai:Error(string `Unsupported (non-text) file type for file ID '${fileId}' ` +
                string `(MIME type '${file.mimeType ?: "unknown"}')`);
        }
        // A named text-less PDF (scanned/image-only or blank) surfaces the descriptive
        // extraction error (from `fetchAndBuild` -> `buildDocument`) to the caller, exactly
        // like any other explicitly named unreadable file.
        return self.fetchAndBuild(file, fileClass);
    }

    // Loads a whole folder. The folder ID is first validated (typo detection): a missing ID
    // is a "not found" error, and a non-folder ID is reported distinctly. Then its supported
    // files are converted to documents, descending into sub-folders when `recursive`.
    private isolated function loadFolder(string folderId, boolean recursive, string[]? includeExtensions)
            returns ai:Document[]|ai:Error {
        drive:File folder = check self.getFileMetadata(folderId);
        if folder.mimeType != GOOGLE_FOLDER_MIME {
            return error ai:Error(string `The ID '${folderId}' does not refer to a folder ` +
                string `(its MIME type is '${folder.mimeType ?: "unknown"}')`);
        }
        // Same typo/intent detection `loadNamedFile` applies: a trashed folder lists no
        // children, so without this check it would silently return zero documents.
        if folder.trashed == true {
            return error ai:Error(
                string `Folder ID '${folderId}' is in the trash and cannot be loaded`);
        }
        return self.listFolder(folderId, recursive, includeExtensions);
    }

    // Lists a folder's children as documents and, when `recursive`, descends into each
    // sub-folder. Trashed files are excluded by the query.
    //
    // Every per-file failure inside a listing is skipped with a logged warning, never
    // propagated: one unreadable file must not discard the documents already collected, nor
    // abandon the rest of the folder. A single non-UTF-8 `.txt`, one corrupt PDF, or one 403
    // on one file would otherwise throw away an entire bulk ingestion.
    //
    // An explicitly named file (`loadNamedFile`) still errors — naming a file expresses intent,
    // so failing to load it is a mistake worth reporting rather than a silent skip.
    private isolated function listFolder(string folderId, boolean recursive, string[]? includeExtensions)
            returns ai:Document[]|ai:Error {
        drive:File[] children = check self.listChildren(folderId);

        ai:Document[] documents = [];
        int skipped = 0;
        foreach drive:File child in children {
            string childMime = child.mimeType ?: "";
            string childName = child.name ?: "";
            // Sub-folders are handled in the recursion pass, not as documents.
            if childMime == GOOGLE_FOLDER_MIME {
                continue;
            }
            if !matchesExtensionFilter(childName, includeExtensions) {
                continue;
            }
            FileClass fileClass = classify(childMime, childName);
            if !isSupported(fileClass) {
                log:printWarn("Skipping a non-text Google Drive file",
                        fileName = childName, mimeType = childMime, folderId = folderId);
                skipped += 1;
                continue;
            }
            string? childId = child.id;
            if childId is () {
                // Drive addresses everything by ID; a child without one cannot be fetched.
                log:printWarn("Skipping a Google Drive file that has no identifier",
                        fileName = childName, folderId = folderId);
                skipped += 1;
                continue;
            }
            // `getAllFiles` accepts no field mask, so the listing carries only Drive's default
            // projection (id/name/mimeType/kind). The timestamps `ai:Metadata` needs therefore
            // cost one `files.get` per child that will actually become a document — an N+1 that
            // cannot be avoided through the connector.
            drive:File|ai:Error full = self.getFileMetadata(childId);
            if full is ai:Error {
                log:printWarn("Skipping a Google Drive file whose metadata could not be retrieved",
                        fileName = childName, fileId = childId, folderId = folderId,
                        reason = full.message());
                skipped += 1;
                continue;
            }
            ai:TextDocument|ai:Error document = self.fetchAndBuild(full, fileClass);
            if document is ai:Error {
                // Any reason at all: a text-less (scanned or blank) PDF, content that will not
                // decode, an export above Drive's 10 MB cap, a file flagged as abusive, a 403 on
                // this one file. The walk continues either way.
                log:printWarn("Skipping a Google Drive file that could not be loaded",
                        fileName = childName, fileId = childId, folderId = folderId,
                        reason = document.message());
                skipped += 1;
                continue;
            }
            documents.push(document);
        }

        // A folder where everything was skipped otherwise looks identical to an empty folder:
        // the caller gets an empty array and would have to read the logs line by line to tell
        // the difference. Summarise it once instead.
        if skipped > 0 {
            log:printWarn("Some Google Drive files in this folder were skipped",
                    folderId = folderId, loaded = documents.length(), skipped = skipped);
        }

        if recursive {
            foreach drive:File child in children {
                if (child.mimeType ?: "") != GOOGLE_FOLDER_MIME {
                    continue;
                }
                string? subFolderId = child.id;
                if subFolderId is string {
                    ai:Document[] childDocuments = check self.listFolder(subFolderId, true, includeExtensions);
                    documents.push(...childDocuments);
                }
            }
        }
        return documents;
    }

    // Fetches a file's content — EXPORTING Google Workspace files and DOWNLOADING ordinary
    // binary files — and converts it to an `ai:TextDocument`. This is the crux of the
    // Drive-specific routing: a Workspace file has no downloadable bytes, so `getFileContent`
    // would fail with `fileNotExportable`; it must go through `exportFile`.
    private isolated function fetchAndBuild(drive:File file, FileClass fileClass)
            returns ai:TextDocument|ai:Error {
        string fileName = file.name ?: "<unnamed>";
        // Drive addresses everything by ID, so a file without one cannot be fetched at all.
        // Substituting "" here would request a nonsense path and surface whatever confusing
        // error Drive returns for it, instead of naming the actual problem.
        string? id = file.id;
        if id is () {
            return error ai:Error(
                string `Encountered a Google Drive file without an identifier (name '${fileName}')`);
        }
        string fileId = id;
        byte[] content;
        // The `Content-Type` of the fetched bytes, whose charset (when Drive reports one)
        // decides how a text download is decoded. `drive:FileContent` carries it verbatim.
        string contentType;
        if requiresExport(fileClass) {
            // `requiresExport` is true only for WORKSPACE_TEXT/WORKSPACE_CSV, and both have an
            // export target, so this is unreachable. Surface it rather than silently defaulting
            // to `text/plain`, which would export a Sheet in the wrong format.
            string? exportTarget = exportMimeTypeFor(fileClass);
            if exportTarget is () {
                return error ai:Error(string `Internal error: file '${fileName}' (ID '${fileId}') ` +
                    string `was routed to the export path but has no export target MIME type`);
            }
            string exportMimeType = exportTarget;
            drive:FileContent|error exported = self.driveClient->exportFile(fileId, exportMimeType);
            if exported is error {
                string? named = describeContentFailure(exported, fileName, fileId);
                if named is string {
                    return error ai:Error(named, exported);
                }
                return error ai:Error(string `Failed to export Google Workspace file '${fileName}' ` +
                    string `(ID '${fileId}') as '${exportMimeType}': ${exported.message()}`, exported);
            }
            content = exported.content;
            contentType = exported.mimeType;
        } else {
            drive:FileContent|error downloaded = self.driveClient->getFileContent(fileId);
            if downloaded is error {
                string? named = describeContentFailure(downloaded, fileName, fileId);
                if named is string {
                    return error ai:Error(named, downloaded);
                }
                return error ai:Error(string `Failed to download file '${fileName}' ` +
                    string `(ID '${fileId}'): ${downloaded.message()}`, downloaded);
            }
            content = downloaded.content;
            contentType = downloaded.mimeType;
        }
        ai:Metadata metadata = buildMetadata(file);
        // Drive's `size` cannot be requested through the connector (see `FILE_FIELDS`), so for a
        // downloaded binary file the byte count IS the file size. An exported Workspace file's
        // export length is not the source file's size, so it is left unset there.
        if !requiresExport(fileClass) {
            metadata.fileSize = <decimal>content.length();
        }
        return buildDocument(content, fileClass, metadata, contentType);
    }

    // Retrieves a file's metadata with the loader's field mask, mapping a missing file to a
    // clear "not found" error (typo detection) and any other failure to a wrapped `ai:Error`.
    private isolated function getFileMetadata(string fileId) returns drive:File|ai:Error {
        drive:File|error file = self.driveClient->getFile(fileId, FILE_FIELDS);
        if file is error {
            if isNotFoundError(file) {
                return error ai:Error(string `File or folder not found for ID '${fileId}'`, file);
            }
            return error ai:Error(
                string `Failed to retrieve metadata for ID '${fileId}': ${file.message()}`, file);
        }
        return file;
    }

    // Lists the immediate children of a folder (files and sub-folders), excluding trashed
    // items via the Drive `q` filter. The connector's `getAllFiles` handles pagination
    // internally, so consuming the returned stream yields every child across all pages.
    private isolated function listChildren(string folderId) returns drive:File[]|ai:Error {
        stream<drive:File>|error fileStream = self.driveClient->getAllFiles(childrenQuery(folderId));
        if fileStream is error {
            if isNotFoundError(fileStream) {
                return error ai:Error(string `Folder not found for ID '${folderId}'`, fileStream);
            }
            return error ai:Error(
                string `Failed to list children of folder '${folderId}': ${fileStream.message()}`,
                fileStream);
        }
        drive:File[]|error children = from drive:File file in fileStream
            select file;
        if children is error {
            // Pagination happens while the stream is consumed, so a failure on any page after
            // the first surfaces here rather than from `getAllFiles`.
            return error ai:Error(
                string `Failed to list children of folder '${folderId}': ${children.message()}`,
                children);
        }
        return children;
    }
}

// Builds the Drive `q` filter selecting a folder's untrashed children.
//
// The ID is interpolated into a single-quoted literal, so an embedded `'` would close the
// literal early and produce a malformed query. Drive's search syntax escapes both `'` and `\`
// with a backslash (https://developers.google.com/workspace/drive/api/guides/search-files).
// Real Drive IDs are opaque base64url and contain neither, but an ID can come from caller input.
isolated function childrenQuery(string folderId) returns string {
    // Backslashes first: escaping quotes first would then double-escape the backslashes this
    // step introduces, and an ID ending in `\` would leave the closing quote escaped.
    string escaped = re `\\`.replaceAll(folderId, "\\\\");
    escaped = re `'`.replaceAll(escaped, "\\'");
    return string `'${escaped}' in parents and trashed = false`;
}

// Resolves a source's `folder` to a Drive ID. The field accepts an ID or a share URL, and
// `driveIdFromUrl` passes a bare ID through unchanged, so one call covers both. `()` means the
// source names no folder.
isolated function resolveFolderId(Source src) returns string?|ai:Error {
    string? folder = src.folder;
    if folder is () {
        return ();
    }
    return driveIdFromUrl(folder);
}

// Resolves a source's explicit `files` to Drive IDs, each entry being an ID or a share URL.
// A fresh mutable array is built explicitly — `src.files` is readonly (sources are stored via
// `cloneReadOnly`), and `.clone()` of an immutable value returns it unchanged, so pushing onto
// a clone would fail with "modification not allowed on readonly value".
isolated function resolveFileIds(Source src) returns string[]|ai:Error {
    string[] fileIds = [];
    foreach string file in src.files {
        fileIds.push(check driveIdFromUrl(file));
    }
    return fileIds;
}
