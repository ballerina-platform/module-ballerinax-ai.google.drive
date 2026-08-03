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

# A rule selecting what to load from Google Drive. Several may be configured per loader.
#
# Unlike a filesystem or Azure Files share, Drive has **no path tree**: every file and
# folder is addressed by an opaque, stable **ID** (a folder is simply a file whose MIME
# type is `application/vnd.google-apps.folder`). A `Source` therefore selects content by
# ID, in one of two ways that may be combined in a single source:
#
# - **A whole folder** — set `folder` to load every supported file directly inside that
#   folder, and set `recursive` to also descend into its sub-folders. Trashed files are
#   always excluded.
# - **Specific files** — list `files` to load those exact files, regardless of where they
#   live. An explicitly listed file is always loaded (subject only to it being a supported
#   type) and bypasses `includeExtensions`.
#
# A source with neither `folder` nor `files` loads nothing.
#
# Both fields accept a Drive **ID or a share URL** interchangeably; a URL is resolved to its
# ID via `driveIdFromUrl`.
public type Source record {|
    # The Drive folder to load files from, given either as a folder ID or as a folder share
    # URL (e.g. `https://drive.google.com/drive/folders/<id>`), from which the ID is
    # extracted. `()` (the default) selects no folder — use `files` for individual files
    # instead.
    string? folder = ();
    # Individual Drive files to load, regardless of folder. Each entry is either a file ID or
    # a share URL (e.g. `https://drive.google.com/file/d/<id>/view`, or a Google Docs
    # `.../d/<id>/edit` URL). An explicitly named file is always loaded and is NOT filtered
    # by `includeExtensions`. Defaults to `[]`.
    string[] files = [];
    # Whether sub-folders under the resolved folder are traversed. Defaults to `false`.
    boolean recursive = false;
    # Case-insensitive extension allowlist applied to folder listings only (never to
    # `files`). Entries may include or omit a leading dot. Defaults to `()`, all types.
    # Note: Google Workspace files (Docs/Sheets/Slides) have no file extension, so an
    # extension allowlist naturally excludes them from folder listings.
    string[]? includeExtensions = ();
|};

// A source with its `folder`/`files` entries already resolved to Drive IDs. Resolution happens
// in `init`, so a source naming an unparseable URL fails immediately rather than part-way
// through a long load, after documents have already been fetched.
type ResolvedSource record {|
    string? folderId;
    string[] fileIds;
    boolean recursive;
    string[]? includeExtensions;
|};


// The Drive `File` metadata fields the loader requests via `getFile`. `getAllFiles` (listing)
// returns only the default projection, so the timestamps needed for `ai:Metadata` are fetched
// explicitly per file with this field mask.
//
// `size` is deliberately NOT requested: the Drive API serialises it as a JSON string (it is an
// int64), but the `googleapis.drive` connector types `File.size` as `int`, so asking for it makes
// the connector's `cloneWithType(File)` fail with "Error occurred while constructing
// DriveResponse record." `ai:Metadata.fileSize` is instead derived from the downloaded byte
// length in `fetchAndBuild` (accurate for binary files; left unset for exported Workspace docs).
//
// `webViewLink` gives a downstream RAG pipeline a citation URL back to the source document, and
// Drive returns it in the same response, so it costs nothing to carry.
const string FILE_FIELDS = "id,name,mimeType,createdTime,modifiedTime,trashed,webViewLink";
