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
# PDFs — whether an uploaded binary or a Workspace file — have their text extracted via
# Apache Tika. See the module documentation for the ID-based `Source` model and the
# supported/exported/unsupported file types.
@display {
    label: "Google Drive Text Data Loader"
}
public isolated class TextDataLoader {
    *ai:DataLoader;

    private final drive:Client driveClient;
    private final readonly & Source[] sources;

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
    # + connection - The Google Drive connector configuration shared by all sources, or an
    #                existing `drive:Client` to reuse (not owned by the loader)
    # + sources - One or more Drive folders and/or file IDs to load documents from
    # + return - An `ai:Error` if the loader could not be initialized
    public isolated function init(@display {label: "Connection"} drive:ConnectionConfig|drive:Client connection,
            @display {label: "Data Sources"} Source[] sources) returns ai:Error? {
        // Validated before the connection is resolved, so it applies to both forms.
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the Google Drive data loader");
        }
        self.sources = sources.cloneReadOnly();
        self.driveClient = connection is drive:Client ? connection : check newDriveClient(connection);
    }

    # Loads the configured Google Drive documents.
    #
    # + return - The loaded document when a single file is resolved, an array of documents
    #            otherwise, or an `ai:Error` on failure
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        foreach Source src in self.sources {
            // Resolve any share URLs (`fileUrls`/`folderUrl`) to Drive IDs, combined with the
            // IDs given directly. From here on the loader is purely ID-based.
            // Explicitly named files are always loaded (subject to being a supported type)
            // and bypass the extension filter — the filter applies to folder listings only.
            foreach string fileId in check resolveFileIds(src) {
                ai:TextDocument document = check self.loadNamedFile(fileId);
                documents.push(document);
            }
            string? folderId = check resolveFolderId(src);
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
        return self.listFolder(folderId, recursive, includeExtensions);
    }

    // Lists a folder's children as documents and, when `recursive`, descends into each
    // sub-folder. Trashed files are excluded by the query. Files that cannot be represented
    // as text are skipped with a logged warning (contrast `loadNamedFile`, which errors).
    private isolated function listFolder(string folderId, boolean recursive, string[]? includeExtensions)
            returns ai:Document[]|ai:Error {
        drive:File[] children = check self.listChildren(folderId);

        ai:Document[] documents = [];
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
                continue;
            }
            // The listing carries only id/name/mimeType; fetch full metadata (size,
            // timestamps) for the supported files that will actually become documents.
            string? childId = child.id;
            if childId is () {
                continue;
            }
            drive:File full = check self.getFileMetadata(childId);
            ai:TextDocument|ai:Error document = self.fetchAndBuild(full, fileClass);
            if document is ai:Error {
                // A text-less PDF (scanned/image-only or blank) has no text to extract;
                // inside a listing it is skipped like other non-text content rather than
                // aborting the whole walk. (An explicitly named one still surfaces the
                // descriptive error to the caller.)
                if isTextlessPdfError(document) {
                    log:printWarn("Skipping a PDF with no extractable text content",
                            fileName = childName, fileId = childId, folderId = folderId);
                    continue;
                }
                return document;
            }
            documents.push(document);
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
        string fileId = file.id ?: "";
        string fileName = file.name ?: "<unnamed>";
        byte[] content;
        if requiresExport(fileClass) {
            string exportMimeType = exportMimeTypeFor(fileClass) ?: EXPORT_MIME_TEXT;
            drive:FileContent|error exported = self.driveClient->exportFile(fileId, exportMimeType);
            if exported is error {
                return error ai:Error(string `Failed to export Google Workspace file '${fileName}' ` +
                    string `(ID '${fileId}') as '${exportMimeType}': ${exported.message()}`, exported);
            }
            content = exported.content;
        } else {
            drive:FileContent|error downloaded = self.driveClient->getFileContent(fileId);
            if downloaded is error {
                return error ai:Error(string `Failed to download file '${fileName}' (ID '${fileId}'): ` +
                    string `${downloaded.message()}`, downloaded);
            }
            content = downloaded.content;
        }
        ai:Metadata metadata = buildMetadata(file);
        // Drive's `size` field cannot be requested (see FILE_FIELDS), so for a downloaded
        // binary file the byte count IS the file size. An exported Workspace file's export
        // length is not the source file's size, so it is left unset there.
        if !requiresExport(fileClass) {
            metadata.fileSize = <decimal>content.length();
        }
        return buildDocument(content, fileClass, metadata);
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
        string filter = string `'${folderId}' in parents and trashed = false`;
        stream<drive:File>|error fileStream = self.driveClient->getAllFiles(filter);
        if fileStream is error {
            return error ai:Error(
                string `Failed to list children of folder '${folderId}': ${fileStream.message()}`, fileStream);
        }
        return from drive:File file in fileStream
            select file;
    }
}

// Resolves a source's folder to a single Drive ID from `folderId` or `folderUrl` (a URL is
// parsed via `driveIdFromUrl`). Setting both is ambiguous and is an error; `()` means the
// source names no folder.
isolated function resolveFolderId(Source src) returns string?|ai:Error {
    string? folderId = src.folderId;
    string? folderUrl = src.folderUrl;
    if folderId is string && folderUrl is string {
        return error ai:Error("A source must set at most one of 'folderId' and 'folderUrl'");
    }
    if folderId is string {
        return folderId;
    }
    if folderUrl is string {
        return driveIdFromUrl(folderUrl);
    }
    return ();
}

// Resolves a source's explicit files to Drive IDs: `fileIds` as given, plus each `fileUrls`
// entry parsed via `driveIdFromUrl`. The two lists combine (order: IDs, then URL-resolved).
// A fresh mutable array is built explicitly — `src.fileIds` is readonly (sources are stored
// via `cloneReadOnly`), and `.clone()` of an immutable value returns it unchanged, so pushing
// onto a clone would fail with "modification not allowed on readonly value".
isolated function resolveFileIds(Source src) returns string[]|ai:Error {
    string[] fileIds = [];
    fileIds.push(...src.fileIds);
    foreach string fileUrl in src.fileUrls {
        fileIds.push(check driveIdFromUrl(fileUrl));
    }
    return fileIds;
}
