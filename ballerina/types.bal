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
# - **A whole folder** — set `folderId` to load every supported file directly inside that
#   folder, and set `recursive` to also descend into its sub-folders. Trashed files are
#   always excluded.
# - **Specific files** — list `fileIds` to load those exact files by ID, regardless of where
#   they live. An explicitly listed file is always loaded (subject only to it being a
#   supported type) and bypasses `includeExtensions`.
#
# A source with none of `folderId`/`folderUrl`/`fileIds`/`fileUrls` loads nothing.
#
# A folder may be given by ID (`folderId`) OR by share URL (`folderUrl`) — set at most one.
# Files may be given by ID (`fileIds`) and/or by share URL (`fileUrls`); the two lists combine.
# Any URL is resolved to its Drive ID via `driveIdFromUrl`.
public type Source record {|
    # The ID of a Drive folder to load files from. `()` (the default) selects no folder.
    # Provide the folder either here or via `folderUrl` (not both) — or use `fileIds`/
    # `fileUrls` for individual files instead.
    string? folderId = ();
    # A Drive share URL for the folder to load, e.g.
    # `https://drive.google.com/drive/folders/<id>` — an alternative to `folderId`; the ID is
    # extracted from the URL. Set at most one of `folderId` / `folderUrl`. Defaults to `()`.
    string? folderUrl = ();
    # Explicit Drive file IDs to load, regardless of folder. An explicitly named file is
    # always loaded and is NOT filtered by `includeExtensions`. Defaults to `[]`.
    string[] fileIds = [];
    # Drive share URLs for individual files to load, e.g.
    # `https://drive.google.com/file/d/<id>/view` or a Google Docs `.../d/<id>/edit` URL —
    # each resolved to its ID and combined with `fileIds`. Like `fileIds`, these bypass
    # `includeExtensions`. Defaults to `[]`.
    string[] fileUrls = [];
    # Whether sub-folders under the resolved folder are traversed. Defaults to `false`.
    boolean recursive = false;
    # Case-insensitive extension allowlist applied to folder listings only (never to
    # `fileIds`). Entries may include or omit a leading dot. Defaults to `()`, all types.
    # Note: Google Workspace files (Docs/Sheets/Slides) have no file extension, so an
    # extension allowlist naturally excludes them from folder listings.
    string[]? includeExtensions = ();
|};

// The Drive `File` metadata fields the loader requests via `getFile`. `getAllFiles`
// (listing) returns only id/name/mimeType, so the timestamps needed for `ai:Metadata` are
// fetched explicitly per file with this field mask.
//
// `size` is deliberately NOT requested: the Drive API serializes it as a JSON string (an
// int64), but the `googleapis.drive` connector types `File.size` as `int`, so asking for it
// makes the connector's `cloneWithType(File)` fail with "Error occurred while constructing
// DriveResponse record." `ai:Metadata.fileSize` is instead derived from the downloaded byte
// length in `fetchAndBuild` (accurate for binary files; left unset for exported Workspace docs).
const string FILE_FIELDS = "id,name,mimeType,createdTime,modifiedTime,trashed";
